-- What a worktree's session looks like: which layout applies to it, the tabs
-- and panes that layout makes, and the session's label. Nothing here calls
-- Rex. The layout builders come in as an argument (rex.layout in Rex), so the
-- tests can run this file under plain Lua 5.1.
--
-- For the same reason, this file also has the path helpers and the bundle
-- builder that init.lua uses.

local L = {}

-- Used when no layout matches: the agent in one tab and a shell in another,
-- or, as a single tab, the agent beside a shell.
L.DEFAULT = {
  repo = "*",
  tabs = {
    { name = "agent", agent = true },
    { name = "terminal" },
  },
  tab = { panes = { { agent = true }, { split = "right" } } },
}

local SHELL = "com.superlogical.terminal.shell"

local function basename(path)
  return (path:gsub("/+$", ""):match("([^/]+)$"))
end

local function expand_home(path)
  if path:sub(1, 2) == "~/" then return (os.getenv("HOME") or "") .. path:sub(2) end
  return path
end

-- What layouts and labels are made from. repo is the forge's name for it, as
-- WorkTrunk reports it, else the main checkout's folder name.
function L.describe(path, branch, main, repo)
  if repo == nil or repo == "" then repo = basename(main) end
  return {
    path   = path,
    branch = branch,
    main   = main,
    repo   = repo,
    names  = { repo:lower(), basename(main):lower() },
  }
end

-- Cut to the server's 128-character limit for labels. A cut text loses its
-- last character when that one is not ASCII, so a cut never splits a character.
function L.cut(text)
  if #text <= 128 then return text end
  return (text:sub(1, 128):gsub("[\192-\255][\128-\191]*$", ""))
end

function L.label(wt)
  return L.cut(wt.repo .. "/" .. wt.branch)
end

-- Converts the terminal's pwd value to a path. A shell that uses OSC 7 reports
-- a file://host/path URL, with a percent-encoded path.
function L.path_of(pwd)
  if pwd == nil or pwd == "" then return nil end
  local path = pwd:match("^file://[^/]*(/.*)$")
  if path == nil then return pwd end
  return (path:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- The parent directory of dir. nil at the root.
function L.parent_of(dir)
  local parent = dir:gsub("/+$", ""):match("^(.*)/[^/]*$")
  if parent == nil then return nil end
  return parent == "" and "/" or parent
end

function L.is_within(dir, root)
  return dir == root or dir:sub(1, #root + 1) == root .. "/"
end

-- Sending Lanes to the machine of a pane. See "How the pieces fit" in init.lua.

-- Converts a value to Lua source. If the value contains a function, returns nil
-- and the place of the function.
function L.serialize(value, where)
  local kind = type(value)
  if kind == "string" then return ("%q"):format(value) end
  if kind == "number" or kind == "boolean" then return tostring(value) end
  if kind ~= "table" then return nil, where end
  local fields = {}
  for k, v in pairs(value) do
    local text, place = L.serialize(v, where .. "." .. tostring(k))
    if text == nil then return nil, place end
    fields[#fields + 1] = "[" .. L.serialize(k, where) .. "]=" .. text
  end
  return "{" .. table.concat(fields, ",") .. "}"
end

-- Makes the Lua script that the modal gives to `rex do`. The script defines
-- lanes_open and lanes_close on the machine that runs it. The fields of parts:
--   init, layout: the source of init.lua and layout.lua.
--   layouts: the source of the layouts.
--   path: the package.path of the config. A layouts file can then require the
--     files next to it, if they are on that machine.
function L.bundle(parts)
  return table.concat({
    ("package.path = %q .. package.path"):format(parts.path .. ";"),
    ('package.preload["lanes.layout"] = assert(loadstring(%q, "=lanes/layout.lua"))'):format(parts.layout),
    ('local lanes = assert(loadstring(%q, "=lanes/init.lua"))("lanes")'):format(parts.init),
    ('lanes.session_actions(assert(loadstring(%q, "=lanes layouts"))())'):format(parts.layouts),
  }, "\n")
end

-- Checking layouts. Each mistake names its place, such as
-- layouts[2].tabs[1].panes[3].split, so a typo can't pass for a default.

local LAYOUT_KEYS = { repo = true, tabs = true, tab = true }
local TAB_KEYS  = { name = true, agent = true, command = true, cwd = true, panes = true }
local PANE_KEYS = { agent = true, command = true, cwd = true, split = true, ratio = true }

local function is_list(t)
  if type(t) ~= "table" then return false end
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n == #t
end

-- A string, or a function of the worktree that returns one.
local function check_value(value, where)
  local kind = type(value)
  if value ~= nil and kind ~= "string" and kind ~= "function" then
    return where .. ": expected a string or a function, got " .. kind
  end
end

local function check_keys(t, allowed, where)
  for k in pairs(t) do
    if not allowed[k] then return where .. ": unknown field " .. tostring(k) end
  end
end

local function check_pane(pane, i, where)
  if type(pane) ~= "table" then return where .. ": expected a table, got " .. type(pane) end
  local err = check_keys(pane, PANE_KEYS, where)
    or check_value(pane.command, where .. ".command")
    or check_value(pane.cwd, where .. ".cwd")
  if err then return err end
  if pane.agent ~= nil and type(pane.agent) ~= "boolean" then
    return where .. ".agent: expected true or false, got " .. type(pane.agent)
  end
  if pane.agent and pane.command ~= nil then return where .. ": give a pane one of agent or command" end
  if i == 1 and (pane.split ~= nil or pane.ratio ~= nil) then
    return where .. ": the first pane has no pane before it to split from"
  end
  if pane.split ~= nil and pane.split ~= "right" and pane.split ~= "down" then
    return where .. '.split: expected "right" or "down", got ' .. tostring(pane.split)
  end
  local r = pane.ratio
  if r ~= nil and (type(r) ~= "number" or r <= 0 or r >= 1) then
    return where .. ".ratio: expected a number between 0 and 1, got " .. tostring(r)
  end
end

local function check_tab(tab, where)
  if type(tab) ~= "table" then return where .. ": expected a table, got " .. type(tab) end
  local err = check_keys(tab, TAB_KEYS, where)
    or check_value(tab.command, where .. ".command")
    or check_value(tab.cwd, where .. ".cwd")
  if err then return err end
  if tab.name ~= nil and type(tab.name) ~= "string" then
    return where .. ".name: expected a string, got " .. type(tab.name)
  end
  if tab.agent ~= nil and type(tab.agent) ~= "boolean" then
    return where .. ".agent: expected true or false, got " .. type(tab.agent)
  end
  local runs = (tab.agent and 1 or 0) + (tab.command ~= nil and 1 or 0) + (tab.panes ~= nil and 1 or 0)
  if runs > 1 then return where .. ": give a tab one of agent, command or panes" end
  if tab.panes ~= nil then
    if not is_list(tab.panes) or #tab.panes == 0 then
      return where .. ".panes: expected a list of one or more panes"
    end
    for i, pane in ipairs(tab.panes) do
      err = check_pane(pane, i, where .. ".panes[" .. i .. "]")
      if err then return err end
    end
  end
end

-- nil when the layouts are fine, else the first mistake.
function L.check(layouts)
  if not is_list(layouts) then return "layouts: expected a list of layouts" end
  for i, layout in ipairs(layouts) do
    local where = "layouts[" .. i .. "]"
    if type(layout) ~= "table" then return where .. ": expected a table, got " .. type(layout) end
    local err = check_keys(layout, LAYOUT_KEYS, where)
    if err then return err end
    if layout.repo ~= nil and type(layout.repo) ~= "string" then
      return where .. ".repo: expected a string, got " .. type(layout.repo)
    end
    if layout.tabs == nil and layout.tab == nil then return where .. ": give a layout tabs or tab" end
    if layout.tabs ~= nil then
      if not is_list(layout.tabs) or #layout.tabs == 0 then
        return where .. ".tabs: expected a list of one or more tabs"
      end
      for j, tab in ipairs(layout.tabs) do
        err = check_tab(tab, where .. ".tabs[" .. j .. "]")
        if err then return err end
      end
    end
    if layout.tab ~= nil then
      err = check_tab(layout.tab, where .. ".tab")
      if err then return err end
      -- One fixed name would label every worktree's tab the same.
      if layout.tab.name ~= nil then return where .. ".tab.name: the tab is labelled with the branch" end
    end
  end
end

-- Picking and building a layout.

-- Names compare without case. A path compares exactly, after ~ is expanded.
local function repo_matches(layout, wt)
  local want = layout.repo or "*"
  if want == "*" then return true end
  if expand_home(want) == wt.main then return true end
  for _, name in ipairs(wt.names) do
    if name == want:lower() then return true end
  end
  return false
end

-- The first layout naming this repo, else the first "*" one, else the default.
-- mode is "session" (the layout's tabs) or "tab" (its tab). A layout without
-- the field for the mode doesn't take part, so in tab mode a repo's tabs-only
-- layout gives way to a "*" one with a tab.
function L.pick(layouts, wt, mode)
  local field = mode == "tab" and "tab" or "tabs"
  local wildcard = L.DEFAULT
  for _, layout in ipairs(layouts) do
    if layout[field] ~= nil then
      if (layout.repo or "*") == "*" then
        if wildcard == L.DEFAULT then wildcard = layout end
      elseif repo_matches(layout, wt) then
        return layout
      end
    end
  end
  return wildcard
end

-- A layout value: a string, or a function of the worktree returning one.
local function resolve(value, wt)
  if type(value) == "function" then return value(wt) end
  return value
end

-- A cwd relative to base, or absolute, or from ~.
local function join(base, dir)
  if dir == nil then return base end
  dir = expand_home(dir)
  return dir:sub(1, 1) == "/" and dir or (base .. "/" .. dir)
end

-- A shell with the command typed in, so quitting it leaves a prompt in place.
-- An agent pane types the agent, and is a plain shell when there is none.
local function pane_block(build, pane, cwd, wt, agent)
  local command
  if pane.agent then command = agent else command = resolve(pane.command, wt) end
  if command == "" then command = nil end
  return build.block{
    flavor  = SHELL,
    options = { cwd = join(cwd, resolve(pane.cwd, wt)), initial_input = command and (command .. "\n") or nil },
  }
end

-- Pane i, then the panes after it split off: the next pane takes its ratio of
-- the space beside ("right") or below ("down") pane i, and the panes after it
-- share that space the same way.
local function panes_layout(build, panes, i, cwd, wt, agent)
  local here = pane_block(build, panes[i], cwd, wt, agent)
  local nxt = panes[i + 1]
  if nxt == nil then return here end
  local split = nxt.split == "right" and build.horizontal or build.vertical
  return split(1 - (nxt.ratio or 0.5), here, panes_layout(build, panes, i + 1, cwd, wt, agent))
end

-- One window: its label and layout. An agent tab with no agent is a plain shell.
function L.window(build, tab, wt, agent, label)
  local cwd = join(wt.path, resolve(tab.cwd, wt))
  local panes = tab.panes or { { agent = tab.agent, command = tab.command } }
  return { window_label = label, layout = panes_layout(build, panes, 1, cwd, wt, agent) }
end

-- The windows session.create takes, in layout order. The agent tab runs agent
-- and is left out when agent is "" or nil.
function L.windows(build, layout, wt, agent)
  local windows = {}
  for _, tab in ipairs(layout.tabs) do
    if not tab.agent or (agent and agent ~= "") then
      windows[#windows + 1] = L.window(build, tab, wt, agent, tab.name)
    end
  end
  return windows
end

-- The window session.new_window takes for the layout's tab, labelled with the
-- branch. It is never left out: the worktree needs somewhere to live.
function L.tab_window(build, layout, wt, agent)
  return L.window(build, layout.tab, wt, agent, L.cut(wt.branch))
end

return L
