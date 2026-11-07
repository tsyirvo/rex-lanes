-- Lanes: create and remove git worktrees from a modal, one Rex session per
-- worktree, laid out per repository. WorkTrunk (`wt`) does the git work.
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
--   runs modal.sh. The two actions return immediately, because an action can't
--   read input and must finish in 30 seconds.
--
--   The modal then runs lanes_open or lanes_close. These actions build or
--   destroy the session.
--
--   lanes_new and lanes_remove run on this machine, but the focused pane can be
--   on a remote host:
--     - rex.exec and io see only this machine.
--     - rex.session, rex.block.call and rex.call reach the pane's machine.
--   So these actions find the repository with the pane's list_dir method. They
--   give the modal the text of modal.sh and of a bundle (see L.bundle), not
--   file paths. A remote host needs no copy of Lanes.
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
-- repo. A worktree's session is labelled {repo}/{branch}, but found again by
-- the ID kept for its path in $XDG_STATE_HOME/rex/lanes.json: agents and
-- people rename sessions, and session IDs survive server restarts.

local L = require((... or "lanes") .. ".layout")

local M = {}

-- Set by release-please on each release.
M.version = "0.1.0" -- x-release-please-version

local SHELL    = "com.superlogical.terminal.shell"
local TERMINAL = "com.superlogical.terminal"

-- The app drops a session.select for a session it hasn't heard of yet, so a
-- new session is shown after this many seconds. A slow remote host may need
-- more.
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
}

local OPTIONS = { agents = true, bounds = true, layouts = true }

-- The first problem that setup found. An error at load would stop the rest of
-- init.lua, and people don't see a log line. So the actions report the problem.
local setup_error

-- The text of modal.sh and of the bundle. Setup reads them.
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

-- The state file: { [worktree path] = session_id }.
local function state_path()
  local dir = os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state")
  return dir .. "/rex/lanes.json"
end

local function read_state()
  local text = read_file(state_path())
  local state = text and rex.json.decode(text)
  return type(state) == "table" and state or {}
end

-- Written to a temporary file and renamed, so a reader never sees half of it.
local function write_state(state)
  local path = state_path()
  rex.exec{ "mkdir", "-p", (path:gsub("/[^/]+$", "")) }
  local f = check(io.open(path .. ".tmp", "w"))
  f:write(check(rex.json.encode(state, { indent = true })))
  f:close()
  check(os.rename(path .. ".tmp", path))
end

-- Remember a worktree's session, or forget it when session_id is nil.
local function remember(path, session_id)
  local state = read_state()
  state[path] = session_id
  write_state(state)
end

local function list_sessions()
  return check(rex.call("session.list")).sessions or {}
end

-- The session kept for a worktree, if it still exists. Entries for sessions
-- that are gone, closed by hand or discarded with the server, are dropped.
local function find_session(wt)
  local live = {}
  for _, s in ipairs(list_sessions()) do
    live[s.session_id] = true
  end
  local state, stale = read_state(), false
  for path, id in pairs(state) do
    if not live[id] then
      state[path] = nil
      stale = true
    end
  end
  if stale then write_state(state) end
  return state[wt.path]
end

-- A connection only reaches sessions it is attached to.
local function terminal_blocks(session_id)
  check(rex.call("session.attach", { session_id = session_id }))
  local ids = {}
  for _, block in ipairs(check(rex.call("session.list_blocks", { session_id = session_id })).blocks or {}) do
    if block.creator_name == TERMINAL then ids[#ids + 1] = block.block_id end
  end
  return ids
end

-- The first session with a pane in the checkout at path, except the given one.
-- This compares git toplevels, not path prefixes: a worktree can be nested in
-- the main checkout, and wt moves a removed worktree into the main checkout's
-- .git, with its panes still in it.
local function session_on(path, except)
  local checkout = git(path, "rev-parse", "--show-toplevel")
  if checkout == nil then return nil end
  for _, s in ipairs(list_sessions()) do
    if s.session_id ~= except then
      for _, block_id in ipairs(terminal_blocks(s.session_id)) do
        local cwd = pane_cwd(block_id, s.session_id)
        if cwd and git(cwd, "rev-parse", "--show-toplevel") == checkout then
          return s.session_id
        end
      end
    end
  end
  return nil
end

-- Tells if the session only has panes in the directory. It reads the reported
-- directories, because the panes' processes are in wt's trash by now. Terminals
-- that report nothing, such as the modal, don't count.
local function only_in(session_id, path)
  local found = false
  for _, block_id in ipairs(terminal_blocks(session_id)) do
    local cwd = reported_cwd(block_id, session_id)
    if cwd then
      if not L.is_within(cwd, path) then return false end
      found = true
    end
  end
  return found
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
  local windows = L.windows(rex.layout, L.pick(M.options.layouts, wt), wt, agent)
  if #windows == 0 then fail("the layout for " .. wt.repo .. " has no tabs to open") end

  local created = check(rex.call("session.create", {
    label = L.label(wt),
    initial_windows = windows,
  }))
  return created.session_id, created.initial_windows[1].window_id
end

-- Show a session in the client that ran the action: the app itself from a key
-- or the palette, the one named with `rex -C` from the modal. The app accepts
-- it from `rex do` only with Remote Control on.
local function show(session_id, window_id)
  rex.client.queue("session.select", { session_id = session_id, window_id = window_id })
end

-- agent is nil when nobody picked one yet. A missing session then comes back
-- as needs_agent instead of being built, so the modal can ask. "" is no agent.
local function open_wt(wt, agent)
  if not is_dir(wt.path) then fail("not a directory: " .. wt.path) end
  local session_id, window_id = find_session(wt) or session_on(wt.path), nil
  local created = session_id == nil
  if created then
    if agent == nil then return { needs_agent = true } end
    session_id, window_id = create_session(wt, agent)
    remember(wt.path, session_id)
    rex.exec{ "sleep", SELECT_DELAY }
  end
  show(session_id, window_id)
  return { session_id = session_id, created = created }
end

-- Open the session for a worktree, creating it when missing.
function M.open(_, path, branch, main, repo, agent)
  return open_wt(L.describe(path, branch, main, repo), agent)
end

-- Close the session of a removed worktree. When the modal ran inside that very
-- session, move to a session on the main checkout, else to the next session.
function M.close(ctx, path, branch, main, repo)
  local session_id = find_session(L.describe(path, branch, main, repo))
  if session_id == nil and ctx.session_id and only_in(ctx.session_id, path) then
    session_id = ctx.session_id
  end
  if session_id == nil then return { closed = false } end
  if session_id == ctx.session_id then
    local target = find_session(L.describe(main, "", main, repo))
      or session_on(main, session_id)
      or next_session(session_id)
    if target then show(target) end
  end
  -- Destroying the session that holds the modal also ends this script.
  remember(path, nil)
  check(rex.call("session.attach", { session_id = session_id }))
  check(rex.call("session.destroy", { session_id = session_id }))
  return { closed = true, session_id = session_id }
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
  modal_text = read_file(dir .. "/modal.sh")
  if not (init and layout and modal_text) then
    return "init.lua, layout.lua or modal.sh is missing from " .. dir
  end
  bundle_text = L.bundle{ init = init, layout = layout, layouts = layouts, path = package.path }
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
    description = "Create a worktree for the repo in the focused pane and open it in its own session.",
    category    = "Lanes",
    keywords    = "git worktree branch create new worktrunk wt agent",
    run = function(ctx) open_modal(ctx, "new") end,
  }

  rex.action{
    name        = "lanes_remove",
    title       = "Lanes: Remove Worktree…",
    description = "Remove a worktree of the repo in the focused pane and close its session.",
    category    = "Lanes",
    keywords    = "git worktree delete remove worktrunk wt",
    run = function(ctx) open_modal(ctx, "remove") end,
  }

  return M
end

-- The bundle calls this function, in the `rex do` that the modal runs.
function M.session_actions(layouts)
  M.options.layouts = layouts

  rex.action{
    name  = "lanes_open",
    title = "Lanes: Open Session",
    args  = { path = "string", branch = "string", main = "string", repo = "string?", agent = "string?" },
    run = function(ctx, args) return M.open(ctx, args.path, args.branch, args.main, args.repo, args.agent) end,
  }

  rex.action{
    name  = "lanes_close",
    title = "Lanes: Close Session",
    args  = { path = "string", branch = "string", main = "string", repo = "string?" },
    run = function(ctx, args) return M.close(ctx, args.path, args.branch, args.main, args.repo) end,
  }
end

return M
