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
--   lanes_new / lanes_remove open a floating terminal (the modal) over the
--   current window, in the repo of the focused pane, running modal.sh. They
--   return at once: an action can't read input, and it has 30 seconds to
--   finish. The modal hands its result back with `rex do` to lanes_open /
--   lanes_close, which build or destroy the session. The modal is given the
--   client that opened it and passes it to `rex -C`, so the switch happens in
--   that app and not in another connected one.
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
M.version = "0.0.0" -- x-release-please-version

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

-- The first mistake setup found in the options. Raising it at load would stop
-- the rest of init.lua, and a log line goes unseen, so the actions report it.
local config_error

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

local function script_path()
  local src = (debug.getinfo(1, "S").source or ""):gsub("^@", "")
  local dir = src:match("^(/.*)/[^/]*$")
    or (os.getenv("XDG_CONFIG_HOME") or (os.getenv("HOME") .. "/.config")) .. "/rex/lanes"
  return dir .. "/modal.sh"
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

-- The main checkout of the repo that dir belongs to.
local function main_of(dir)
  local common = git(dir, "rev-parse", "--path-format=absolute", "--git-common-dir")
  return common and (common:gsub("/%.git/?$", "")) or nil
end

-- The directory the focused terminal is in: its foreground program's, else its
-- shell's, else what it last reported. nil rather than a guess, since acting on
-- the wrong repo is worse than refusing.
local function focused_cwd(block_id)
  if not block_id then return nil end
  local p = rex.block.call(TERMINAL, "process", { block_id = block_id })
  if p then
    local cwd = (p.foreground or {}).cwd or (p.child or {}).cwd
    if cwd and cwd ~= "" then return cwd end
  end
  local pwd = rex.block.call(TERMINAL, "pwd", { block_id = block_id })
  return pwd and pwd.pwd ~= "" and pwd.pwd or nil
end

-- The state file: { [worktree path] = session_id }.
local function state_path()
  local dir = os.getenv("XDG_STATE_HOME") or (os.getenv("HOME") .. "/.local/state")
  return dir .. "/rex/lanes.json"
end

local function read_state()
  local f = io.open(state_path(), "r")
  if f == nil then return {} end
  local state = rex.json.decode(f:read("*a"))
  f:close()
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

-- The session kept for a worktree, if it still exists. Entries for sessions
-- that are gone, closed by hand or discarded with the server, are dropped.
local function find_session(wt)
  local live = {}
  for _, s in ipairs(check(rex.call("session.list")).sessions or {}) do
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
  local session_id, window_id = find_session(wt), nil
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
-- session, move to the main checkout's session first.
function M.close(ctx, path, branch, main, repo)
  local session_id = find_session(L.describe(path, branch, main, repo))
  if session_id == nil then return { closed = false } end
  if session_id == ctx.session_id and is_dir(main) then
    open_wt(L.describe(main, git(main, "branch", "--show-current") or "", main, repo), "")
  end
  -- A connection only reaches sessions it is attached to.
  check(rex.call("session.attach", { session_id = session_id }))
  check(rex.call("session.destroy", { session_id = session_id }))
  remember(path, nil)
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
  if config_error then fail("fix the setup in init.lua: " .. config_error) end
  local cwd = focused_cwd(ctx.block_id)
  if cwd == nil then fail("can't tell which repo the focused pane is in") end
  local main = main_of(cwd)
  if main == nil then fail("not a git repository: " .. cwd) end

  local command = { "bash", script_path(), mode, ctx.client_id or "" }
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

function M.setup(opts)
  opts = opts or {}
  config_error = check_options(opts)
  if config_error then
    rex.log("error", "lanes: " .. config_error)
  else
    for k, v in pairs(opts) do M.options[k] = v end
  end

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

  -- Called by modal.sh.
  local wt_args = { path = "string", branch = "string", main = "string", repo = "string?" }

  rex.action{
    name        = "lanes_open",
    title       = "Lanes: Open Session",
    description = "Used by the Lanes modal: open a worktree's session, building it when missing.",
    category    = "Lanes",
    args        = { path = "string", branch = "string", main = "string", repo = "string?", agent = "string?" },
    run = function(ctx, args) return M.open(ctx, args.path, args.branch, args.main, args.repo, args.agent) end,
  }

  rex.action{
    name        = "lanes_close",
    title       = "Lanes: Close Session",
    description = "Used by the Lanes modal: close the session of a removed worktree.",
    category    = "Lanes",
    args        = wt_args,
    run = function(ctx, args) return M.close(ctx, args.path, args.branch, args.main, args.repo) end,
  }

  return M
end

return M
