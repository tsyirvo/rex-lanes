-- Tests for layout.lua. Run from the repo root with Lua 5.1:
--
--   lua tests/layout_test.lua

package.path = "./?.lua;" .. package.path
local L = require("layout")

-- Builds the same tables as rex.layout in Rex.
local build = {
  block = function(spec) return { block = spec } end,
  horizontal = function(ratio, a, b)
    return { split = { direction = "horizontal", ratio = ratio, before = a, after = b } }
  end,
  vertical = function(ratio, a, b)
    return { split = { direction = "vertical", ratio = ratio, before = a, after = b } }
  end,
}

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
  if text == nil or not text:find(part, 1, true) then
    error("expected a message with " .. part .. ", got " .. tostring(text), 2)
  end
end

local HOME = os.getenv("HOME") or ""
local wt = L.describe("/src/app.feat", "feat", "/src/app", "My-App")

-- describe and label

test("describe falls back to the folder name without a forge name", function()
  eq(L.describe("/w", "b", "/src/folder/", "").repo, "folder")
  eq(L.describe("/w", "b", "/src/folder", nil).repo, "folder")
end)

test("label is repo/branch", function()
  eq(L.label(wt), "My-App/feat")
end)

test("a long label is cut to 128 bytes", function()
  local label = L.label{ repo = "r", branch = string.rep("a", 200) }
  eq(#label, 128, "length")
end)

test("a cut never splits a multibyte character", function()
  -- "r/" plus 125 bytes, then "é" (2 bytes) straddles the 128th byte.
  local label = L.label{ repo = "r", branch = string.rep("a", 125) .. "éé" }
  eq(#label, 127, "length")
  eq(label:sub(-1), "a", "last character")
end)

-- pick

test("a layout matches the forge name without case", function()
  local mine = { repo = "my-app", tabs = { { name = "x" } } }
  eq(L.pick({ mine }, wt), mine)
end)

test("a layout matches the folder name", function()
  local mine = { repo = "APP", tabs = { { name = "x" } } }
  eq(L.pick({ mine }, wt), mine)
end)

test("a layout matches the main checkout's path, with ~", function()
  local here = L.describe(HOME .. "/src/x.b", "b", HOME .. "/src/x", "x")
  local mine = { repo = "~/src/x", tabs = { { name = "x" } } }
  eq(L.pick({ mine }, here), mine)
end)

test("a named layout wins over an earlier wildcard", function()
  local any = { repo = "*", tabs = { { name = "any" } } }
  local mine = { repo = "my-app", tabs = { { name = "mine" } } }
  eq(L.pick({ any, mine }, wt), mine)
end)

test("the first wildcard applies when no name matches", function()
  local first = { tabs = { { name = "first" } } }
  local second = { repo = "*", tabs = { { name = "second" } } }
  local other = { repo = "other", tabs = { { name = "other" } } }
  eq(L.pick({ other, first, second }, wt), first)
end)

test("the default applies with no layouts", function()
  eq(L.pick({}, wt), L.DEFAULT)
end)

-- windows

test("the agent tab runs the agent", function()
  local windows = L.windows(build, L.DEFAULT, wt, "claude")
  eq(#windows, 2, "windows")
  eq(windows[1].window_label, "agent")
  eq(windows[1].layout.block.options.initial_input, "claude\n")
  eq(windows[1].layout.block.options.cwd, "/src/app.feat")
  eq(windows[2].layout.block.options.initial_input, nil, "plain shell input")
end)

test("the agent tab is left out with no agent", function()
  eq(#L.windows(build, L.DEFAULT, wt, ""), 1, "with \"\"")
  eq(#L.windows(build, L.DEFAULT, wt, nil), 1, "with nil")
end)

test("panes split right and down with their ratios", function()
  local layout = { tabs = { { panes = {
    { command = "a" },
    { split = "right", ratio = 0.3 },
    { split = "down" },
  } } } }
  local top = L.windows(build, layout, wt, "")[1].layout.split
  eq(top.direction, "horizontal")
  eq(top.ratio, 0.7, "first pane's share")
  eq(top.before.block.options.initial_input, "a\n")
  eq(top.after.split.direction, "vertical")
  eq(top.after.split.ratio, 0.5)
end)

test("cwd joins relative, absolute and ~ paths", function()
  local layout = { tabs = {
    { cwd = "mobile", panes = { {}, { cwd = "ios" } } },
    { cwd = "/tmp" },
    { cwd = "~/x" },
  } }
  local windows = L.windows(build, layout, wt, "")
  local split = windows[1].layout.split
  eq(split.before.block.options.cwd, "/src/app.feat/mobile")
  eq(split.after.block.options.cwd, "/src/app.feat/mobile/ios")
  eq(windows[2].layout.block.options.cwd, "/tmp")
  eq(windows[3].layout.block.options.cwd, HOME .. "/x")
end)

test("command and cwd can be functions of the worktree", function()
  local layout = { tabs = { {
    cwd = function(w) return w.branch end,
    command = function(w) return "echo " .. w.repo end,
  } } }
  local block = L.windows(build, layout, wt, "")[1].layout.block
  eq(block.options.cwd, "/src/app.feat/feat")
  eq(block.options.initial_input, "echo My-App\n")
end)

test("a function returning nil or \"\" leaves a plain shell", function()
  local layout = { tabs = {
    { command = function() return nil end },
    { command = function() return "" end },
  } }
  local windows = L.windows(build, layout, wt, "")
  eq(windows[1].layout.block.options.initial_input, nil)
  eq(windows[2].layout.block.options.initial_input, nil)
end)

-- check

test("the example layouts and the default pass", function()
  eq(L.check(dofile("layouts.example.lua")), nil)
  eq(L.check({ L.DEFAULT }), nil)
  eq(L.check({}), nil)
end)

local function mistake(layouts)
  local err = L.check(layouts)
  if err == nil then error("expected a mistake", 2) end
  return err
end

local function one_tab(tab) return { { tabs = { tab } } } end

test("layouts must be a list of tables with tabs", function()
  has(mistake("x"), "layouts: expected a list")
  has(mistake({ repo = "x" }), "layouts: expected a list")
  has(mistake({ { repo = "x" } }), "layouts[1].tabs: expected a list")
  has(mistake({ { tabs = {} } }), "layouts[1].tabs: expected a list")
  has(mistake({ { repo = 3, tabs = { {} } } }), "layouts[1].repo: expected a string")
end)

test("an unknown field is a mistake", function()
  has(mistake({ { repos = "x", tabs = { {} } } }), "layouts[1]: unknown field repos")
  has(mistake(one_tab({ comand = "x" })), "layouts[1].tabs[1]: unknown field comand")
  has(mistake(one_tab({ panes = { {}, { spilt = "right" } } })), "panes[2]: unknown field spilt")
end)

test("a tab has at most one of agent, command and panes", function()
  has(mistake(one_tab({ agent = true, command = "x" })), "one of agent, command or panes")
  has(mistake(one_tab({ command = "x", panes = { {} } })), "one of agent, command or panes")
  has(mistake(one_tab({ agent = "yes" })), "tabs[1].agent: expected true or false")
end)

test("split must be right or down", function()
  has(mistake(one_tab({ panes = { {}, { split = "left" } } })),
    'layouts[1].tabs[1].panes[2].split: expected "right" or "down", got left')
end)

test("the first pane can't split", function()
  has(mistake(one_tab({ panes = { { split = "right" } } })), "panes[1]: the first pane has no pane")
  has(mistake(one_tab({ panes = { { ratio = 0.5 } } })), "panes[1]: the first pane has no pane")
end)

test("ratio must be between 0 and 1", function()
  for _, r in ipairs({ 0, 1, 1.5, "half" }) do
    has(mistake(one_tab({ panes = { {}, { split = "down", ratio = r } } })), "panes[2].ratio")
  end
end)

test("command and cwd must be strings or functions", function()
  has(mistake(one_tab({ command = 3 })), "tabs[1].command: expected a string or a function")
  has(mistake(one_tab({ panes = { { cwd = true } } })), "panes[1].cwd: expected a string or a function")
end)

print(("%d passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
