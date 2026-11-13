-- Lanes: create and remove git worktrees from a modal, one Rex session or tab
-- per worktree (see `open`), laid out per repository. WorkTrunk (`wt`) does the git work.
--
-- Clone into ~/.config/rex/lanes, copy layouts.example.lua to
-- ~/.config/rex/lanes-layouts.lua, then in ~/.config/rex/init.lua:
--
--   require("lanes").setup{ layouts = require("lanes-layouts") }
--   rex.bind("cmd+alt+n", "lanes_new")
--   rex.bind("cmd+alt+backspace", "lanes_remove")
--
-- How the pieces fit:
--   lanes_new and lanes_remove open a floating terminal (the modal) over the
--   current window. The modal starts in the directory of the focused pane and
--   runs modal.sh with picker.sh. The two actions return immediately, because
--   an action can't read input and must finish in 30 seconds.
--
--   The modal then runs lanes_open or lanes_close. These actions build or
--   close the worktree's session or tab (its lane).
--
--   lanes_new and lanes_remove run on this machine, but the focused pane can be
--   on a remote host:
--     - rex.exec and io see only this machine.
--     - rex.session, rex.block.call and rex.call reach the pane's machine.
--   So these actions find the repository with the pane's list_dir method. They
--   give the modal the text of those scripts and of a bundle (see L.bundle),
--   not file paths. A remote host needs no copy of Lanes.
--
--   The modal runs the bundle with `rex do` on the pane's machine. lanes_open
--   and lanes_close exist only there. They can use rex.exec, io and the state
--   file, because the worktree and its sessions are on that machine. Each
--   machine has its own state file.
--
--   The modal gets the client that opened it and passes it to `rex -C`. The
--   switch then occurs in that app, not in another connected app. A remote
--   server knows that app by a different ID. In that case the modal omits -C,
--   and Rex uses the only connected app.
--
--   Switching the app to another session from `rex do` needs Remote Control
--   (Rex → Settings → Rex Server). Without it the session is still created,
--   and the modal says how to reach it.
--
-- Layouts (see layout.lua and layouts.example.lua) pick the tabs and panes per
-- repo. A worktree's session is labelled {repo}/{branch} and its tab {branch},
-- but both are found again by the IDs kept for its path in
-- $XDG_STATE_HOME/rex/lanes.json: agents and people rename them, and session
-- IDs survive server restarts.

local L = require((... or "lanes") .. ".layout")

local M = {}

-- Set by release-please on each release.
M.version = "0.1.0" -- x-release-please-version

local SHELL    = "com.superlogical.terminal.shell"
local TERMINAL = "com.superlogical.terminal"

-- The app drops a session.select for a session it hasn't heard of yet, so a
-- new session is shown after this many seconds. A slow remote host may need
-- more. A new tab needs no wait: it opens in the session on screen, active.
local SELECT_DELAY = "0.2"

M.options = {
  -- Agent commands offered in the modal, first is the default. nil asks Rex
  -- for the agents it supports (`rex skill status`). Either way the modal
  -- shows only those whose program is on PATH, then "terminal only".
  agents = nil,
  -- The modal's x, y, width, height, as fractions of the window.
  bounds = { 0.2, 0.15, 0.6, 0.6 },
  -- See layouts.example.lua.
  layouts = {},
  -- How a new worktree opens: "session", a session of its own, or "tab", one
  -- tab in the session the modal was opened from. Either way, a worktree that
  -- already has a session or a tab goes there.
  open = "session",
}

local OPTIONS = { agents = true, bounds = true, layouts = true, open = true }

-- The first problem that setup found. An error at load would stop the rest of
-- init.lua, and people don't see a log line. So the actions report the problem.
local setup_error

-- The text of the modal's scripts and of the bundle. Setup reads them.
local modal_text, bundle_text

-- The modal layer open in each session, so a second press replaces it.
local modals = {}

local function fail(message)
  error("lanes: " .. message, 0)
end

local function check(result, err)
  if result == nil then fail(tostring(err)) end
  return result
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- The directory that contains Lanes.
local function install_dir()
  local src = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
  return src:match("^(/.*)/[^/]*$")
    or (os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")) .. "/rex/lanes"
end

local function read_file(path)
  local f = io.open(path, "r")
  if f == nil then return nil end
  local text = f:read("*a")
  f:close()
  return text
end

local function is_dir(path)
  local r = rex.exec{ "test", "-d", path }
  return r ~= nil and r.ok
end

local function git(dir, ...)
  local r = rex.exec({ "git", "-C", dir, ... }, { timeout = 5 })
  if r and r.ok then return trim(r.stdout) end
  return nil
end

-- The directory the shell last reported, which stays the same if that directory
-- moves.
local function reported_cwd(block_id, session_id)
  local pwd = rex.block.call(TERMINAL, "pwd", { block_id = block_id, session_id = session_id })
  return pwd and L.path_of(pwd.pwd)
end

-- The directory a terminal is in: its foreground program's, else its
-- shell's, else what it last reported. nil rather than a guess, since acting on
-- the wrong repo is worse than refusing.
local function pane_cwd(block_id, session_id)
  if not block_id then return nil end
  local p = rex.block.call(TERMINAL, "process", { block_id = block_id, session_id = session_id })
  if p then
    local cwd = (p.foreground or {}).cwd or (p.child or {}).cwd
    if cwd and cwd ~= "" then return cwd end
  end
  return reported_cwd(block_id, session_id)
end

-- Tells if dir is in a git repository, on the machine of the block. The search
-- starts at dir and goes up to the root. A directory that the block can't read
-- has no entries, so the search continues above it. A .git entry is a directory,
-- or a file in a worktree or a submodule.
local function in_repo(block_id, dir)
  while dir do
    local listing, err = rex.block.call(TERMINAL, "list_dir", {
      block_id = block_id, path = dir, prefix = ".git", files = true,
    })
    if listing == nil then
      fail("can't look for a git repository in " .. dir .. ": " .. tostring(err))
    end
    for _, entry in ipairs(listing.entries or {}) do
      if entry.name == ".git" then return true end
    end
    dir = L.parent_of(dir)
  end
  return false
end

-- Where a worktree lives is its lane: { session_id } for a whole session, or
-- { session_id, window_id } for one tab of a session.

-- The state file: { [worktree path] = session_id or { session_id, window_id } }.
-- A session lane is written as a bare ID, as older versions wrote every entry.
local function state_path()
  local dir = os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state")
  return dir .. "/rex/lanes.json"
end

local function as_lane(value)
  if type(value) == "string" then return { session_id = value } end
  if type(value) == "table" and type(value.session_id) == "string" then
    return { session_id = value.session_id, window_id = type(value.window_id) == "string" and value.window_id or nil }
  end
  return nil
end

local function read_state()
  local text = read_file(state_path())
  local raw = text and rex.json.decode(text)
  local state = {}
  if type(raw) == "table" then
    for path, value in pairs(raw) do
      if type(path) == "string" then state[path] = as_lane(value) end
    end
  end
  return state
end

-- Written to a temporary file and renamed, so a reader never sees half of it.
local function write_state(state)
  local raw = {}
  for path, lane in pairs(state) do
    raw[path] = lane.window_id and { session_id = lane.session_id, window_id = lane.window_id } or lane.session_id
  end
  local path = state_path()
  rex.exec{ "mkdir", "-p", (path:gsub("/[^/]+$", "")) }
  local f = check(io.open(path .. ".tmp", "w"))
  f:write(check(rex.json.encode(raw, { indent = true })))
  f:close()
  check(os.rename(path .. ".tmp", path))
end

-- Remember a worktree's lane, or forget it when lane is nil.
local function remember(path, lane)
  local state = read_state()
  state[path] = lane
  write_state(state)
end

local function list_sessions()
  return check(rex.call("session.list")).sessions or {}
end

-- Every block of a session: { block_id, creator_name, window_id }. window_id is
-- nil for a block in no window, such as a detached one. A connection only
-- reaches sessions it is attached to. nil and the error when the session can't
-- be listed.
local function blocks_of(session_id)
  local ok, err = rex.call("session.attach", { session_id = session_id })
  if ok == nil then return nil, err end
  local listed
  listed, err = rex.call("session.list_blocks", { session_id = session_id })
  if listed == nil then return nil, err end
  local blocks = {}
  for _, b in ipairs(listed.blocks or {}) do
    blocks[#blocks + 1] = {
      block_id = b.block_id,
      creator_name = b.creator_name,
      window_id = type(b.window_id) == "string" and b.window_id or nil,
    }
  end
  return blocks
end

local function terminals(blocks)
  local found = {}
  for _, b in ipairs(blocks) do
    if b.creator_name == TERMINAL then found[#found + 1] = b end
  end
  return found
end

-- The windows of a session, as a set, or nil if it can't be listed.
local function windows_of(session_id)
  local blocks = blocks_of(session_id)
  if blocks == nil then return nil end
  local windows = {}
  for _, b in ipairs(blocks) do
    if b.window_id then windows[b.window_id] = true end
  end
  return windows
end

-- Tells if a lane still exists. live caches what Rex reported: live.sessions,
-- the set of sessions, and live.windows, each session's windows (false when it
-- couldn't be listed).
local function lane_alive(lane, live)
  if not live.sessions[lane.session_id] then return false end
  if lane.window_id == nil then return true end
  local windows = live.windows[lane.session_id]
  if windows == nil then
    windows = windows_of(lane.session_id) or false
    live.windows[lane.session_id] = windows
  end
  return windows and windows[lane.window_id] == true or false
end

-- The lane kept for a worktree, if it still exists. Entries for lanes that are
-- gone, closed by hand or discarded with the server, are dropped.
local function find_lane(wt)
  local live = { sessions = {}, windows = {} }
  for _, s in ipairs(list_sessions()) do
    live.sessions[s.session_id] = true
  end
  local state, stale = read_state(), false
  for path, lane in pairs(state) do
    if not lane_alive(lane, live) then
      state[path] = nil
      stale = true
    end
  end
  if stale then write_state(state) end
  return state[wt.path]
end

-- The first tab with a pane in the checkout at path, outside the given session.
-- This compares git toplevels, not path prefixes: a worktree can be nested in
-- the main checkout, and wt moves a removed worktree into the main checkout's
-- .git, with its panes still in it. A place to show, never a lane to remember
-- or close: the tab may have been opened by hand.
local function lane_on(path, except)
  local checkout = git(path, "rev-parse", "--show-toplevel")
  if checkout == nil then return nil end
  for _, s in ipairs(list_sessions()) do
    if s.session_id ~= except then
      for _, b in ipairs(terminals(check(blocks_of(s.session_id)))) do
        if b.window_id then
          local cwd = pane_cwd(b.block_id, s.session_id)
          if cwd and git(cwd, "rev-parse", "--show-toplevel") == checkout then
            return { session_id = s.session_id, window_id = b.window_id }
          end
        end
      end
    end
  end
  return nil
end

-- The windows of a session whose panes are all in the directory, and whether
-- that is the whole session. It reads the reported directories, because the
-- panes' processes are in wt's trash by now. Terminals that report nothing,
-- such as the modal, don't count, and a window none of whose terminals report
-- is neither in nor out. keep is a set of windows never to count as in.
local function windows_in(session_id, path, keep)
  local verdict, order = {}, {}
  for _, b in ipairs(terminals(check(blocks_of(session_id)))) do
    local w = b.window_id
    if w then
      if verdict[w] == nil then
        order[#order + 1] = w
        verdict[w] = "silent"
      end
      local cwd = reported_cwd(b.block_id, session_id)
      if cwd and verdict[w] ~= "out" then
        verdict[w] = (L.is_within(cwd, path) and not (keep and keep[w])) and "in" or "out"
      end
    end
  end
  local inside, whole = {}, true
  for _, w in ipairs(order) do
    if verdict[w] == "in" then inside[#inside + 1] = w end
    if verdict[w] == "out" then whole = false end
  end
  return inside, whole and #inside > 0
end

-- The session after the given one, wrapping around. nil if it is the only one.
local function next_session(session_id)
  local sessions = list_sessions()
  for i, s in ipairs(sessions) do
    if s.session_id == session_id then
      local following = sessions[i % #sessions + 1].session_id
      return following ~= session_id and following or nil
    end
  end
  return nil
end

local function create_session(wt, agent)
  local windows = L.windows(rex.layout, L.pick(M.options.layouts, wt, "session"), wt, agent)
  if #windows == 0 then fail("the layout for " .. wt.repo .. " has no tabs to open") end

  local created = check(rex.call("session.create", {
    label = L.label(wt),
    initial_windows = windows,
  }))
  rex.exec{ "sleep", SELECT_DELAY }
  return { session_id = created.session_id, window_id = created.initial_windows[1].window_id }
end

local function create_tab(wt, agent, session_id)
  if session_id == nil then fail("lanes_open opens a tab in its session: run it from a Rex terminal") end
  local window = L.tab_window(rex.layout, L.pick(M.options.layouts, wt, "tab"), wt, agent)
  check(rex.call("session.attach", { session_id = session_id }))
  local created = check(rex.call("session.new_window", {
    session_id = session_id,
    window_label = window.window_label,
    layout = window.layout,
  }))
  return { session_id = session_id, window_id = created.window_id }
end

-- Show a lane in the client that ran the action: the app itself from a key or
-- the palette, the one named with `rex -C` from the modal. The app accepts it
-- from `rex do` only with Remote Control on.
local function show(lane)
  rex.client.queue("session.select", { session_id = lane.session_id, window_id = lane.window_id })
end

-- agent is nil when nobody picked one yet. A missing lane then comes back as
-- needs_agent instead of being built, so the modal can ask. "" is no agent.
local function open_wt(wt, agent, session_id)
  if not is_dir(wt.path) then fail("not a directory: " .. wt.path) end
  local lane = find_lane(wt) or lane_on(wt.path)
  local created = lane == nil
  if created then
    if agent == nil then return { needs_agent = true } end
    if M.options.open == "tab" then
      lane = create_tab(wt, agent, session_id)
      remember(wt.path, lane)
    else
      lane = create_session(wt, agent)
      remember(wt.path, { session_id = lane.session_id })
    end
  end
  show(lane)
  return { session_id = lane.session_id, window_id = lane.window_id, created = created }
end

-- Open the lane for a worktree, creating it when missing. A tab opens in the
-- session the action runs from, the modal's.
function M.open(ctx, path, branch, main, repo, agent)
  return open_wt(L.describe(path, branch, main, repo), agent, ctx.session_id)
end

-- Rex picks a neighboring tab when the active one closes, and the modal is a
-- layer on the session, not in a tab, so nothing needs moving.
local function close_tabs(session_id, windows)
  for _, window_id in ipairs(windows) do
    local ok, err = rex.call("session.close_window", { session_id = session_id, window_id = window_id })
    -- not_found: the tab is already gone.
    if ok == nil and not tostring(err):find("code=not_found", 1, true) then fail(tostring(err)) end
  end
  return { closed = true, session_id = session_id, windows_closed = #windows }
end

-- Destroy a session lane. When the modal ran inside that very session, first
-- move to a lane on the main checkout, else to the next session.
local function destroy_session(ctx, session_id, path, main, repo)
  if session_id == ctx.session_id then
    local target = find_lane(L.describe(main, "", main, repo)) or lane_on(main, session_id)
    if target == nil then
      local following = next_session(session_id)
      target = following and { session_id = following }
    end
    if target then show(target) end
  end
  -- Destroying the session that holds the modal also ends this script.
  remember(path, nil)
  check(rex.call("session.attach", { session_id = session_id }))
  check(rex.call("session.destroy", { session_id = session_id }))
  return { closed = true, session_id = session_id }
end

-- The tabs that other worktrees' kept lanes have in the session, as a set.
local function other_tabs(session_id, path)
  local tabs = {}
  for other, lane in pairs(read_state()) do
    if other ~= path and lane.session_id == session_id and lane.window_id then tabs[lane.window_id] = true end
  end
  return tabs
end

local function count(set)
  local n = 0
  for _ in pairs(set) do n = n + 1 end
  return n
end

-- Close the lane of a removed worktree:
--   - A tab closes, or its whole session when it is the session's only tab: an
--     empty session would stay behind.
--   - A session that also holds other worktrees' tabs stays, giving up only the
--     tabs whose panes are all in the worktree.
--   - Without a kept lane, the modal's session gives up the tabs whose panes
--     are all in the worktree, and the whole session goes when that is every
--     tab.
function M.close(ctx, path, branch, main, repo)
  local lane = find_lane(L.describe(path, branch, main, repo))
  if lane == nil then
    if ctx.session_id == nil then return { closed = false } end
    local inside, whole = windows_in(ctx.session_id, path)
    if #inside == 0 then return { closed = false } end
    if not whole then return close_tabs(ctx.session_id, inside) end
    lane = { session_id = ctx.session_id }
  elseif lane.window_id then
    if count(windows_of(lane.session_id) or {}) > 1 then
      remember(path, nil)
      return close_tabs(lane.session_id, { lane.window_id })
    end
  else
    local keep = other_tabs(lane.session_id, path)
    if next(keep) then
      remember(path, nil)
      return close_tabs(lane.session_id, (windows_in(lane.session_id, path, keep)))
    end
  end
  return destroy_session(ctx, lane.session_id, path, main, repo)
end

local function close_modal(session_id)
  local layer_id = modals[session_id]
  if layer_id then
    rex.session.close_layer{ layer_id = layer_id }
    modals[session_id] = nil
  end
end

local function open_modal(ctx, mode)
  if setup_error then fail(setup_error) end
  local cwd = pane_cwd(ctx.block_id)
  if cwd == nil then fail("can't tell which repo the focused pane is in") end
  if not in_repo(ctx.block_id, cwd) then fail("not a git repository: " .. cwd) end

  local command = { "bash", "-c", modal_text, "lanes", mode, ctx.client_id or "", bundle_text }
  if mode == "new" then
    if M.options.agents == nil then
      command[#command + 1] = "rex"
    else
      command[#command + 1] = "list"
      for _, agent in ipairs(M.options.agents) do
        -- "" meant "no agent" in older setups. The modal always offers that.
        if agent ~= "" then command[#command + 1] = agent end
      end
    end
  end

  close_modal(ctx.session_id)
  local layer = check(rex.session.new_layer{
    bounds = M.options.bounds,
    focus  = true,
    layout = { block = { flavor = SHELL, label = "lanes", options = { command = command, cwd = cwd } } },
  })
  modals[ctx.session_id] = layer.layer_id
end

-- nil when the options are fine, else the first mistake.
local function check_options(opts)
  for k in pairs(opts) do
    if not OPTIONS[k] then return "unknown option " .. tostring(k) end
  end
  if opts.open ~= nil and opts.open ~= "session" and opts.open ~= "tab" then
    return 'open: expected "session" or "tab", got ' .. tostring(opts.open)
  end
  local agents = opts.agents
  if agents ~= nil then
    if type(agents) ~= "table" then return "agents: expected a list of commands" end
    for i, agent in ipairs(agents) do
      if type(agent) ~= "string" then return "agents[" .. i .. "]: expected a string" end
    end
  end
  local b = opts.bounds
  if b ~= nil then
    if type(b) ~= "table" or #b ~= 4 then return "bounds: expected { x, y, width, height }" end
    for i = 1, 4 do
      if type(b[i]) ~= "number" or b[i] < 0 or b[i] > 1 then
        return "bounds[" .. i .. "]: expected a fraction of the window, 0 to 1"
      end
    end
  end
  if opts.layouts ~= nil then return L.check(opts.layouts) end
end

-- The source text of the module that returned layouts. nil if no module did.
local function module_source(layouts)
  for name, value in pairs(package.loaded) do
    if value == layouts then
      local file = name:gsub("%.", "/")
      for template in package.path:gmatch("[^;]+") do
        local text = read_file((template:gsub("%?", file)))
        if text then return text end
      end
    end
  end
  return nil
end

-- Lua source that returns the layouts. Lanes sends a layouts file without
-- changes. Lanes serializes layouts from init.lua, but it can't serialize a
-- function. In that case, this returns nil and the mistake.
local function layouts_source(layouts)
  local source = module_source(layouts)
  if source then return source end
  local text, place = L.serialize(layouts, "layouts")
  if text == nil then
    return nil, place .. ": a function needs the layouts in a file of their own, loaded with require"
  end
  return "return " .. text
end

-- Sets modal_text and bundle_text. Returns the problem if it can't.
local function prepare()
  local layouts, err = layouts_source(M.options.layouts)
  if layouts == nil then return "fix the setup in init.lua: " .. err end
  local dir = install_dir()
  local init, layout = read_file(dir .. "/init.lua"), read_file(dir .. "/layout.lua")
  local picker, modal = read_file(dir .. "/picker.sh"), read_file(dir .. "/modal.sh")
  if not (init and layout and picker and modal) then
    return "init.lua, layout.lua, picker.sh or modal.sh is missing from " .. dir
  end
  modal_text = picker .. "\n" .. modal
  bundle_text = L.bundle{ init = init, layout = layout, layouts = layouts, open = M.options.open, path = package.path }
end

function M.setup(opts)
  opts = opts or {}
  local mistake = check_options(opts)
  if mistake then
    setup_error = "fix the setup in init.lua: " .. mistake
  else
    for k, v in pairs(opts) do M.options[k] = v end
    setup_error = prepare()
  end
  if setup_error then rex.log("error", "lanes: " .. setup_error) end

  rex.action{
    name        = "lanes_new",
    title       = "Lanes: New Worktree…",
    description = "Create a worktree for the repo in the focused pane and open it in its own session or tab.",
    category    = "Lanes",
    keywords    = "git worktree branch create new worktrunk wt agent",
    run = function(ctx) open_modal(ctx, "new") end,
  }

  rex.action{
    name        = "lanes_remove",
    title       = "Lanes: Remove Worktree…",
    description = "Remove a worktree of the repo in the focused pane and close its session or tab.",
    category    = "Lanes",
    keywords    = "git worktree delete remove worktrunk wt",
    run = function(ctx) open_modal(ctx, "remove") end,
  }

  return M
end

-- The bundle calls this function, in the `rex do` that the modal runs, with the
-- config the actions need: { layouts, open }.
function M.session_actions(config)
  M.options.layouts = config.layouts
  M.options.open = config.open or "session"

  rex.action{
    name  = "lanes_open",
    title = "Lanes: Open Session or Tab",
    args  = { path = "string", branch = "string", main = "string", repo = "string?", agent = "string?" },
    run = function(ctx, args) return M.open(ctx, args.path, args.branch, args.main, args.repo, args.agent) end,
  }

  rex.action{
    name  = "lanes_close",
    title = "Lanes: Close Session or Tab",
    args  = { path = "string", branch = "string", main = "string", repo = "string?" },
    run = function(ctx, args) return M.close(ctx, args.path, args.branch, args.main, args.repo) end,
  }
end

return M
