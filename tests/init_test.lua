-- Tests for init.lua and its bundle, with a fake rex. Run from the repo root
-- with Lua 5.1:
--
--   lua tests/init_test.lua

package.path = "./?.lua;" .. package.path
package.preload["lanes.layout"] = function() return require("layout") end

-- init.lua uses its own path to find its files. This path must be absolute.
local ROOT = assert(os.getenv("PWD"), "PWD is not set")
local INIT = ROOT .. "/init.lua"

-- init.lua keeps its state file in XDG_STATE_HOME. The fake rex.exec makes no
-- directories, and the tests must not write to the real state file. So they get
-- a temporary directory that already contains rex/.
local STATE_HOME = os.tmpname()
os.remove(STATE_HOME)
assert(os.execute("mkdir -p '" .. STATE_HOME .. "/rex'") == 0, "can't make the state directory")

local real_getenv = os.getenv
os.getenv = function(name)
  if name == "XDG_STATE_HOME" then return STATE_HOME end
  return real_getenv(name)
end

local passed, failed = 0, 0

local function test(name, fn)
  local ok, err = pcall(fn)
  if ok then
    passed = passed + 1
  else
    failed = failed + 1
    print("FAIL " .. name .. "\n     " .. tostring(err))
  end
end

local function eq(actual, expected, what)
  if actual ~= expected then
    error((what or "value") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
  end
end

local function has(text, part)
  if text == nil or not tostring(text):find(part, 1, true) then
    error("expected a message with " .. part .. ", got " .. tostring(text), 2)
  end
end

local state

-- A fake Rex. state holds the directories and repositories of the pane. The
-- pane is on a remote host, so rex.exec fails on this machine.
local function fake_rex()
  state = {
    actions = {}, logs = {}, layers = {}, created = {}, queued = {},
    sessions = {}, blocks = {}, panes = {}, destroyed = {}, closed_windows = {}, new_windows = {},
    cwd = "/srv/repo/sub", pwd = nil, git = { ["/srv/repo"] = true },
    exec = function(argv) error("rex.exec on the wrong machine: " .. table.concat(argv, " "), 0) end,
  }
  rex = {
    action = function(a) state.actions[a.name] = a end,
    log = function(level, message) state.logs[#state.logs + 1] = level .. ": " .. message end,
    exec = function(argv, opts) return state.exec(argv, opts) end,
    layout = {
      block = function(spec) return { block = spec } end,
      horizontal = function(r, a, b) return { r, a, b } end,
      vertical = function(r, a, b) return { r, a, b } end,
    },
    json = {
      decode = function() return state.saved or {} end,
      encode = function(value)
        state.saved = value
        return "{}"
      end,
    },
    block = {
      call = function(_, method, args)
        local pane = state.panes[args.block_id]
        if pane then
          if method == "process" then return { foreground = { cwd = pane.cwd } } end
          if method == "pwd" then return { pwd = pane.pwd } end
        end
        if method == "process" then
          return state.cwd and { child = { cwd = state.cwd } } or {}
        end
        if method == "pwd" then return { pwd = state.pwd } end
        if method == "list_dir" then
          -- Rex also returns these entries for the prefix ".git".
          local entries = { { name = ".github" }, { name = ".gitignore", file = true } }
          if state.git[args.path] then entries[#entries + 1] = { name = ".git" } end
          return { entries = entries }
        end
      end,
    },
    session = {
      new_layer = function(args)
        state.layers[#state.layers + 1] = args
        return { layer_id = "layer" .. #state.layers }
      end,
      close_layer = function() return {} end,
    },
    call = function(method, args)
      if method == "session.list" then return { sessions = state.sessions } end
      if method == "session.list_blocks" then return { blocks = state.blocks[args.session_id] or {} } end
      if method == "session.close_window" then
        for _, b in ipairs(state.blocks[args.session_id] or {}) do
          if b.window_id == args.window_id then
            state.closed_windows[#state.closed_windows + 1] = args.window_id
            return { revision = 1 }
          end
        end
        return nil, 'window ' .. args.window_id .. ' not found (status=404 code=not_found)'
      end
      if method == "session.destroy" then
        state.destroyed[#state.destroyed + 1] = args.session_id
        state.saved_at_destroy = state.saved
      end
      if method == "session.new_window" then
        state.new_windows[#state.new_windows + 1] = args
        return { window_id = "new" .. #state.new_windows, block_ids = { "nb" } }
      end
      if method == "session.create" then
        state.created[#state.created + 1] = args
        return { session_id = "s1", initial_windows = { { window_id = "w1" } } }
      end
      return {}
    end,
    client = { queue = function(name, args) state.queued[#state.queued + 1] = { name, args } end },
  }
end

local function load_lanes()
  return assert(loadfile(INIT))("lanes")
end

local function setup(opts)
  fake_rex()
  return load_lanes().setup(opts)
end

-- Runs an action. Returns the error message if the action fails.
local function run(name, ctx)
  local ok, err = pcall(state.actions[name].run, ctx or { session_id = "s0", block_id = "b1", client_id = "c1" }, {})
  return (not ok) and err or nil
end

local function modal_command()
  return state.layers[1].layout.block.options.command
end

-- Loads the bundle of the modal, as `rex do` does.
local function load_bundle()
  package.preload["lanes.layout"] = nil
  package.loaded["lanes.layout"] = nil
  state.actions = {}
  -- The bundle prepends the config's package.path, which a real `rex do` starts
  -- without. Kept, it would double with each bundle the tests load.
  local saved_path = package.path
  assert(loadstring(modal_command()[7], "=bundle"))()
  package.path = saved_path
  package.preload["lanes.layout"] = function() return require("layout") end
end

test("the modal is the text of picker.sh and modal.sh, not a path", function()
  setup({})
  eq(run("lanes_new"), nil)
  local command = modal_command()
  eq(command[1], "bash")
  eq(command[2], "-c")
  has(command[3], "The new-worktree picker")
  has(command[3], "The worktree modal")
  eq(command[4], "lanes")
  eq(command[5], "new")
  eq(command[6], "c1")
  eq(command[8], "rex", "the agents' source")
end)

test("the modal starts in the pane's directory, not the repo root", function()
  setup({})
  eq(run("lanes_remove"), nil)
  eq(state.layers[1].layout.block.options.cwd, "/srv/repo/sub")
  eq(modal_command()[5], "remove")
end)

test("configured agents follow the bundle", function()
  setup({ agents = { "claude", "", "codex --full-auto" } })
  eq(run("lanes_new"), nil)
  local command = modal_command()
  eq(command[8], "list")
  eq(command[9], "claude")
  eq(command[10], "codex --full-auto")
end)

test("the repo is found through the pane, without rex.exec", function()
  setup({})
  state.cwd = "/srv/repo/a/b/c"
  eq(run("lanes_new"), nil)
end)

test("outside a repo the action fails, opening no modal", function()
  setup({})
  state.git = {}
  has(run("lanes_new"), "not a git repository: /srv/repo/sub")
  eq(#state.layers, 0)
end)

test("a .gitignore or .github isn't a repo", function()
  setup({})
  state.git = {}
  state.cwd = "/srv/repo"
  has(run("lanes_new"), "not a git repository")
end)

test("the pwd fallback reads an OSC 7 URL", function()
  setup({})
  state.cwd = nil
  state.pwd = "file://host/srv/repo/my%20dir"
  eq(run("lanes_new"), nil)
  eq(state.layers[1].layout.block.options.cwd, "/srv/repo/my dir")
end)

test("the config registers only the keys' actions", function()
  setup({})
  eq(state.actions.lanes_open, nil)
  eq(state.actions.lanes_close, nil)
  assert(state.actions.lanes_new and state.actions.lanes_remove)
end)

test("the bundle defines the session actions and builds a session", function()
  setup({ layouts = { { repo = "*", tabs = { { name = "only" } } } } })
  eq(run("lanes_new"), nil)
  load_bundle()
  assert(state.actions.lanes_open and state.actions.lanes_close)
  eq(state.actions.lanes_new, nil, "lanes_new in the bundle")

  state.exec = function() return { ok = true, stdout = "" } end
  local ctx = { session_id = "s0" }
  local out = state.actions.lanes_open.run(ctx, { path = "/srv/repo", branch = "b", main = "/srv/repo", agent = "" })
  eq(out.created, true)
  eq(state.created[1].initial_windows[1].window_label, "only")
  eq(state.queued[1][1], "session.select")
end)

test("a layouts module is sent as its source, functions included", function()
  fake_rex()
  local path = os.tmpname()
  local f = assert(io.open(path .. ".lua", "w"))
  f:write('local function up() return "from-source" end\n')
  f:write('return { { repo = "*", tabs = { { name = "t", command = function() return up() end } } } }\n')
  f:close()

  local dir, base = path:match("^(.*)/([^/]+)$")
  local saved = package.path
  package.path = dir .. "/?.lua;" .. saved
  local layouts = require(base)
  local lanes = load_lanes().setup({ layouts = layouts })
  eq(run("lanes_new"), nil, "lanes_new")
  eq(lanes.options.layouts, layouts)
  package.loaded[base] = nil
  load_bundle()
  package.path = saved
  os.remove(path .. ".lua")
  os.remove(path)

  state.exec = function() return { ok = true, stdout = "" } end
  state.actions.lanes_open.run({ session_id = "s0" }, { path = "/srv/repo", branch = "b", main = "/srv/repo", agent = "" })
  eq(state.created[1].initial_windows[1].layout.block.options.initial_input, "from-source\n")
end)

test("a function in layouts written in init.lua is reported", function()
  setup({ layouts = { { repo = "*", tabs = { { command = function() return "x" end } } } } })
  has(run("lanes_new"), "layouts.1.tabs.1.command: a function needs the layouts in a file of their own")
  eq(#state.layers, 0)
end)

test("open must be session or tab", function()
  setup({ open = "window" })
  has(run("lanes_new"), 'open: expected "session" or "tab", got window')
end)

test("a setup mistake is reported by the actions", function()
  setup({ bogus = true })
  has(run("lanes_new"), "fix the setup in init.lua: unknown option bogus")
end)

test("a missing install file is reported once, with one prefix", function()
  fake_rex()
  local f = assert(io.open(INIT))
  local source = f:read("*a")
  f:close()
  assert(loadstring(source, "@/nonexistent/init.lua"))("lanes").setup({})
  eq(run("lanes_new"), "lanes: init.lua, layout.lua, picker.sh or modal.sh is missing from /nonexistent")
  eq(#state.layers, 0)
end)

-- Removing a worktree. /srv/repo is the main checkout. /srv/repo.feat, the
-- worktree, is already removed, so only its session's panes know about it.

local MAIN, WORKTREE = "/srv/repo", "/srv/repo.feat"

-- Each session is { id, pane, pane... }, and each pane is { cwd = ..., pwd = ... },
-- with window = ... for a tab other than the session's one tab, id .. "-w", or
-- window = false for a detached pane. The modal is in no tab. A cwd's toplevel
-- is the cwd itself, or the part before /mobile.
local function session_actions(sessions, opts)
  setup(opts or {})
  eq(run("lanes_new"), nil)
  load_bundle()
  for _, spec in ipairs(sessions) do
    local blocks = { { block_id = "modal-" .. spec[1], creator_name = "other" } }
    for i = 2, #spec do
      local block_id = spec[1] .. "-" .. i
      local window = spec[i].window
      if window == nil then window = spec[1] .. "-w" end
      blocks[#blocks + 1] = { block_id = block_id, creator_name = "com.superlogical.terminal", window_id = window or nil }
      state.panes[block_id] = spec[i]
    end
    state.sessions[#state.sessions + 1] = { session_id = spec[1], label = spec[1] }
    state.blocks[spec[1]] = blocks
  end
  state.exec = function(argv)
    if argv[1] ~= "git" then return { ok = true, stdout = "" } end
    local dir = argv[3]
    if dir:find("/.git/", 1, true) then return { ok = false, stdout = "" } end
    return { ok = true, stdout = (dir:gsub("/mobile$", "")) .. "\n" }
  end
end

local function track(path, session_id)
  state.saved = state.saved or {}
  state.saved[path] = session_id
  local f = assert(io.open(STATE_HOME .. "/rex/lanes.json", "w"))
  f:write("{}")
  f:close()
end

local function close(from)
  return state.actions.lanes_close.run({ session_id = from }, { path = WORKTREE, branch = "feat", main = MAIN })
end

local function shown()
  local last = state.queued[#state.queued]
  return last and last[2].session_id, last and last[2].window_id
end

local IN_WORKTREE = { cwd = MAIN .. "/.git/wt/trash/feat", pwd = "file://host" .. WORKTREE }
local IN_WORKTREE_TAB = { cwd = IN_WORKTREE.cwd, pwd = IN_WORKTREE.pwd, window = "tab2" }

test("removing goes to a session on the main checkout that Lanes didn't create", function()
  session_actions({
    { "other", { cwd = "/srv/other" } },
    { "wt", IN_WORKTREE },
    { "main", { cwd = MAIN } },
  })
  track(WORKTREE, "wt")
  local out = close("wt")
  eq(shown(), "main")
  eq(#state.created, 0, "sessions created")
  eq(state.destroyed[1], "wt")
  eq(out.closed, true)
end)

test("a pane in a subfolder of the main checkout counts", function()
  session_actions({ { "wt", IN_WORKTREE }, { "main", { cwd = MAIN .. "/mobile" } } })
  track(WORKTREE, "wt")
  close("wt")
  eq(shown(), "main")
end)

test("the first session on the main checkout wins", function()
  session_actions({ { "wt", IN_WORKTREE }, { "first", { cwd = MAIN } }, { "second", { cwd = MAIN } } })
  track(WORKTREE, "wt")
  close("wt")
  eq(shown(), "first")
end)

test("without a session on the main checkout, the next session is shown", function()
  session_actions({ { "a", { cwd = "/srv/a" } }, { "wt", IN_WORKTREE }, { "b", { cwd = MAIN .. ".other" } } })
  track(WORKTREE, "wt")
  close("wt")
  eq(shown(), "b")
  eq(#state.created, 0, "sessions created")
end)

test("a pane in wt's trash isn't on the main checkout", function()
  session_actions({ { "wt", IN_WORKTREE }, { "stale", IN_WORKTREE }, { "main", { cwd = MAIN } } })
  track(WORKTREE, "wt")
  close("wt")
  eq(shown(), "main")
end)

test("the next session wraps around to the first", function()
  session_actions({ { "a", { cwd = "/srv/a" } }, { "wt", IN_WORKTREE } })
  track(WORKTREE, "wt")
  close("wt")
  eq(shown(), "a")
end)

test("the only session closes without moving anywhere", function()
  session_actions({ { "wt", IN_WORKTREE } })
  track(WORKTREE, "wt")
  close("wt")
  eq(#state.queued, 0, "selects")
  eq(state.destroyed[1], "wt")
end)

test("removing from another session stays there", function()
  session_actions({ { "here", { cwd = "/srv/a" } }, { "wt", IN_WORKTREE }, { "main", { cwd = MAIN } } })
  track(WORKTREE, "wt")
  close("here")
  eq(#state.queued, 0, "selects")
  eq(state.destroyed[1], "wt")
end)

test("the state entry is gone before the session is destroyed", function()
  session_actions({ { "wt", IN_WORKTREE }, { "main", { cwd = MAIN } } })
  track(WORKTREE, "wt")
  close("wt")
  eq(state.saved_at_destroy[WORKTREE], nil)
end)

test("an untracked session with panes only in the worktree is closed", function()
  session_actions({ { "wt", IN_WORKTREE, { cwd = "x", pwd = WORKTREE .. "/mobile" } }, { "main", { cwd = MAIN } } })
  eq(close("wt").closed, true)
  eq(shown(), "main")
  eq(state.destroyed[1], "wt")
end)

test("an untracked session with a pane elsewhere is left alone", function()
  session_actions({ { "mixed", IN_WORKTREE, { cwd = "/srv/a", pwd = "/srv/a" } }, { "main", { cwd = MAIN } } })
  eq(close("mixed").closed, false)
  eq(#state.queued, 0, "selects")
  eq(#state.destroyed, 0, "destroyed")
end)

test("opening a checkout goes to a session on it, without asking for an agent", function()
  session_actions({ { "main", { cwd = MAIN .. "/mobile" } } })
  local out = state.actions.lanes_open.run({ session_id = "main" }, { path = MAIN, branch = "b", main = MAIN })
  eq(out.session_id, "main")
  eq(out.created, false)
  eq(#state.created, 0, "sessions created")
end)

test("opening goes to the exact tab with a pane in the checkout", function()
  session_actions({ { "main", { cwd = "/srv/a" }, { cwd = MAIN, window = "tab2" } } })
  local out = state.actions.lanes_open.run({ session_id = "main" }, { path = MAIN, branch = "b", main = MAIN })
  local session_id, window_id = shown()
  eq(session_id, "main")
  eq(window_id, "tab2")
  eq(out.created, false)
end)

test("a detached pane is never a place to go", function()
  session_actions({ { "main", { cwd = MAIN, window = false } } })
  local out = state.actions.lanes_open.run({ session_id = "main" }, { path = MAIN, branch = "b", main = MAIN })
  eq(out.needs_agent, true)
end)

test("an untracked tab with panes only in the worktree is closed, keeping the session", function()
  session_actions({ { "here", { cwd = "/srv/a", pwd = "/srv/a" }, { cwd = "x", pwd = WORKTREE, window = "tab2" } } })
  local out = close("here")
  eq(out.closed, true)
  eq(out.windows_closed, 1)
  eq(state.closed_windows[1], "tab2")
  eq(#state.destroyed, 0, "destroyed")
  eq(#state.queued, 0, "selects")
end)

test("a tab with a pane outside the worktree is never closed", function()
  session_actions({ { "here", { cwd = "/srv/a", pwd = "/srv/a" },
    { cwd = "x", pwd = WORKTREE, window = "tab2" }, { cwd = "y", pwd = "/srv/b", window = "tab2" } } })
  eq(close("here").closed, false)
  eq(#state.closed_windows, 0, "windows closed")
end)

-- Tab mode

local function open_feat(ctx)
  state.exec = function() return { ok = true, stdout = "" } end
  return state.actions.lanes_open.run(ctx, { path = WORKTREE, branch = "feat", main = MAIN, agent = "claude" })
end

test("in tab mode, a new worktree opens as a tab in the modal's session", function()
  setup({ open = "tab" })
  eq(run("lanes_new"), nil)
  load_bundle()
  local out = open_feat({ session_id = "s0" })
  eq(out.created, true)
  eq(#state.created, 0, "sessions created")
  local args = state.new_windows[1]
  eq(args.session_id, "s0")
  eq(args.window_label, "feat")
  eq(args.layout[2].block.options.initial_input, "claude\n", "the default tab's agent pane")
  local session_id, window_id = shown()
  eq(session_id, "s0")
  eq(window_id, "new1")
  eq(state.saved[WORKTREE].session_id, "s0")
  eq(state.saved[WORKTREE].window_id, "new1")
end)

test("in tab mode, the layout's tab is used", function()
  setup({ open = "tab", layouts = { { repo = "*", tabs = { {} }, tab = { command = "make" } } } })
  eq(run("lanes_new"), nil)
  load_bundle()
  open_feat({ session_id = "s0" })
  eq(state.new_windows[1].layout.block.options.initial_input, "make\n")
end)

test("in tab mode, opening by hand outside Rex fails clearly", function()
  setup({ open = "tab" })
  eq(run("lanes_new"), nil)
  load_bundle()
  local ok, err = pcall(open_feat, {})
  eq(ok, false)
  has(err, "run it from a Rex terminal")
end)

test("a worktree's session is found whatever the mode", function()
  session_actions({ { "here", { cwd = "/srv/a" } }, { "wt", { cwd = "/elsewhere" } } }, { open = "tab" })
  track(WORKTREE, "wt")
  local out = open_feat({ session_id = "here" })
  eq(out.created, false)
  eq(shown(), "wt")
  eq(#state.new_windows, 0, "tabs created")
end)

test("a worktree's tab is found in session mode", function()
  session_actions({ { "here", { cwd = "/srv/a" }, { cwd = "/elsewhere", window = "tab2" } } })
  track(WORKTREE, { session_id = "here", window_id = "tab2" })
  local out = open_feat({ session_id = "here" })
  eq(out.created, false)
  eq(#state.created, 0, "sessions created")
  local _, window_id = shown()
  eq(window_id, "tab2")
end)

test("removing a worktree closes its tab and keeps the session", function()
  session_actions({ { "here", { cwd = "/srv/a" }, IN_WORKTREE_TAB } })
  track(WORKTREE, { session_id = "here", window_id = "tab2" })
  local out = close("here")
  eq(out.closed, true)
  eq(state.closed_windows[1], "tab2")
  eq(#state.destroyed, 0, "destroyed")
  eq(#state.queued, 0, "selects")
  eq(state.saved[WORKTREE], nil)
end)

test("a tab that is its session's only tab takes the session with it", function()
  session_actions({ { "here", { cwd = "/srv/a", window = "tab2" } }, { "main", { cwd = MAIN } } })
  track(WORKTREE, { session_id = "here", window_id = "tab2" })
  close("here")
  eq(state.destroyed[1], "here")
  eq(shown(), "main")
end)

test("removing a worktree keeps another worktree's tab in its session", function()
  session_actions({ { "wt", IN_WORKTREE, { cwd = "/srv/repo.b", pwd = "/srv/repo.b", window = "tab2" } } })
  track(WORKTREE, "wt")
  track("/srv/repo.b", { session_id = "wt", window_id = "tab2" })
  local out = close("wt")
  eq(out.closed, true)
  eq(#state.destroyed, 0, "destroyed")
  eq(#state.closed_windows, 1, "windows closed")
  eq(state.closed_windows[1], "wt-w")
  eq(state.saved[WORKTREE], nil)
  eq(state.saved["/srv/repo.b"].window_id, "tab2")
end)

-- State files

local function write_raw(raw)
  state.saved = raw
  local f = assert(io.open(STATE_HOME .. "/rex/lanes.json", "w"))
  f:write("{}")
  f:close()
end

test("an old state file's session IDs still open their sessions", function()
  session_actions({ { "wt", { cwd = "/elsewhere" } } })
  write_raw({ ["/srv/repo"] = "wt" })
  local out = state.actions.lanes_open.run({ session_id = "wt" }, { path = MAIN, branch = "b", main = MAIN })
  eq(out.session_id, "wt")
  eq(out.created, false)
end)

test("junk entries are dropped and session lanes are written back as IDs", function()
  session_actions({ { "wt", { cwd = "/elsewhere" } } })
  write_raw({ ["/srv/repo"] = "wt", ["/junk"] = 3, ["/junk2"] = { window_id = "x" }, ["/gone"] = "nope" })
  state.actions.lanes_open.run({ session_id = "wt" }, { path = MAIN, branch = "b", main = MAIN })
  eq(state.saved["/srv/repo"], "wt")
  eq(state.saved["/junk"], nil)
  eq(state.saved["/junk2"], nil)
  eq(state.saved["/gone"], nil)
end)

test("a tab entry whose tab is gone is stale, a live one is kept", function()
  session_actions({ { "s", { cwd = "/elsewhere" }, { cwd = "/elsewhere", window = "tab2" } } })
  write_raw({
    ["/srv/repo"] = { session_id = "s", window_id = "gone" },
    ["/srv/live"] = { session_id = "s", window_id = "tab2" },
    ["/srv/other"] = { session_id = "missing", window_id = "tab2" },
  })
  local out = state.actions.lanes_open.run({ session_id = "s" }, { path = MAIN, branch = "b", main = MAIN })
  eq(out.needs_agent, true)
  eq(state.saved["/srv/repo"], nil)
  eq(state.saved["/srv/other"], nil)
  eq(state.saved["/srv/live"].window_id, "tab2")
end)

test("a detached pane doesn't keep a tab entry alive", function()
  session_actions({ { "s", { cwd = "/elsewhere" }, { cwd = "/elsewhere", window = false } } })
  write_raw({ ["/srv/repo"] = { session_id = "s", window_id = "tab9" } })
  eq(state.actions.lanes_open.run({ session_id = "s" }, { path = MAIN, branch = "b", main = MAIN }).needs_agent, true)
end)

os.execute("rm -rf '" .. STATE_HOME .. "'")

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
