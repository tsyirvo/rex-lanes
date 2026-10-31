-- What a worktree's session looks like: which layout applies to it, the tabs
-- and panes that layout makes, and the session's label. Nothing here calls
-- Rex. The layout builders come in as an argument (rex.layout in Rex), so the
-- tests can run this file under plain Lua 5.1.

local L = {}

-- Used when no layout matches: the agent in one tab, a shell in another.
L.DEFAULT = {
  repo = "*",
  tabs = {
    { name = "agent", agent = true },
    { name = "terminal" },
  },
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

-- Cut to the server's 128-character limit. A cut label loses its last
-- character when that one is not ASCII, so a cut never splits a character.
function L.label(wt)
  local label = wt.repo .. "/" .. wt.branch
  if #label <= 128 then return label end
  return (label:sub(1, 128):gsub("[\192-\255][\128-\191]*$", ""))
end

-- Checking layouts. Each mistake names its place, such as
-- layouts[2].tabs[1].panes[3].split, so a typo can't pass for a default.

local TAB_KEYS  = { name = true, agent = true, command = true, cwd = true, panes = true }
local PANE_KEYS = { command = true, cwd = true, split = true, ratio = true }

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
    local err = check_keys(layout, { repo = true, tabs = true }, where)
    if err then return err end
    if layout.repo ~= nil and type(layout.repo) ~= "string" then
      return where .. ".repo: expected a string, got " .. type(layout.repo)
    end
    if not is_list(layout.tabs) or #layout.tabs == 0 then
      return where .. ".tabs: expected a list of one or more tabs"
    end
    for j, tab in ipairs(layout.tabs) do
      err = check_tab(tab, where .. ".tabs[" .. j .. "]")
      if err then return err end
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
function L.pick(layouts, wt)
  local wildcard = L.DEFAULT
  for _, layout in ipairs(layouts) do
    if (layout.repo or "*") == "*" then
      if wildcard == L.DEFAULT then wildcard = layout end
    elseif repo_matches(layout, wt) then
      return layout
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
local function pane_block(build, pane, cwd, wt)
  local command = resolve(pane.command, wt)
  if command == "" then command = nil end
  return build.block{
    flavor  = SHELL,
    options = { cwd = join(cwd, resolve(pane.cwd, wt)), initial_input = command and (command .. "\n") or nil },
  }
end

-- Pane i, then the panes after it split off: the next pane takes its ratio of
-- the space beside ("right") or below ("down") pane i, and the panes after it
-- share that space the same way.
local function panes_layout(build, panes, i, cwd, wt)
  local here = pane_block(build, panes[i], cwd, wt)
  local nxt = panes[i + 1]
  if nxt == nil then return here end
  local split = nxt.split == "right" and build.horizontal or build.vertical
  return split(1 - (nxt.ratio or 0.5), here, panes_layout(build, panes, i + 1, cwd, wt))
end

-- The windows session.create takes, in layout order. The agent tab runs agent
-- and is left out when agent is "" or nil.
function L.windows(build, layout, wt, agent)
  local windows = {}
  for _, tab in ipairs(layout.tabs) do
    if not tab.agent or (agent and agent ~= "") then
      local cwd = join(wt.path, resolve(tab.cwd, wt))
      local panes = tab.panes or { { command = tab.agent and agent or tab.command } }
      windows[#windows + 1] = { window_label = tab.name, layout = panes_layout(build, panes, 1, cwd, wt) }
    end
  end
  return windows
end

return L
