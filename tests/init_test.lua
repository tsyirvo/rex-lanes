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
      decode = function() return {} end,
      encode = function() return "{}" end,
    },
    block = {
      call = function(_, method, args)
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
      if method == "session.list" then return { sessions = {} } end
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
  assert(loadstring(modal_command()[7], "=bundle"))()
  package.preload["lanes.layout"] = function() return require("layout") end
end

test("the modal is the text of modal.sh, not a path", function()
  setup({})
  eq(run("lanes_new"), nil)
  local command = modal_command()
  eq(command[1], "bash")
  eq(command[2], "-c")
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
  eq(run("lanes_new"), "lanes: init.lua, layout.lua or modal.sh is missing from /nonexistent")
  eq(#state.layers, 0)
end)

os.execute("rm -rf '" .. STATE_HOME .. "'")

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
