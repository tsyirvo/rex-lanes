-- Lanes layouts: the tabs and panes a new worktree session opens with. Copy
-- this file to ~/.config/rex/lanes-layouts.lua and change it to fit.
--
-- The first layout whose `repo` matches wins, else the first `repo = "*"` one.
-- `repo` is the repo's name on its forge (as WorkTrunk reports it) or the main
-- checkout's folder name, compared without case, or the main checkout's path
-- (~ allowed), compared exactly.
--
-- A tab has at most one of agent, command and panes:
--   name     the tab's label
--   agent    true: runs the agent picked in the modal; left out when none is
--   command  typed into the tab's shell (a tab without one is a plain shell)
--   panes    a list of panes
--   cwd      where the tab starts, relative to the worktree
--
-- A pane:
--   command  typed into the pane's shell
--   split    "right" (beside) or "down" (below, the default) the pane before
--            it. The first pane has none.
--   ratio    the share of that split the pane takes, more than 0 and less
--            than 1 (default 0.5). The panes after it share that same part.
--   cwd      relative to the tab's cwd
--
-- command and cwd can also be a function(wt) returning one, where wt has
-- path, branch, main and repo.
--
-- Lanes checks this file when Rex loads it. A mistake, such as an unknown
-- field or split = "left", is reported when lanes_new or lanes_remove runs.

local function has(wt, file)
  local f = io.open(wt.path .. "/" .. file, "r")
  if f then f:close() end
  return f ~= nil
end

return {
  -- A JavaScript app: install dependencies beside a free shell, and keep the
  -- dev server in a tab of its own.
  {
    repo = "my-app",
    tabs = {
      { name = "agent", agent = true },
      { name = "terminal", panes = {
        { command = function(wt) return has(wt, "bun.lock") and "bun install" or "npm install" end },
        { split = "right" },
      } },
      { name = "dev", command = "npm run dev" },
    },
  },
  {
    repo = "*",
    tabs = {
      { name = "agent", agent = true },
      { name = "terminal" },
    },
  },
}
