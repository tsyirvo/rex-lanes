# Lanes

Lanes gives each git worktree its own [Rex](https://www.superlogical.com/) session, with a coding agent in it.

Press a key, type a branch, pick an agent. Lanes creates the worktree with [WorkTrunk](https://worktrunk.dev), runs its hooks in view, and opens a session laid out the way you set for that repo. Press another key to remove the worktree and close its session.

- **One session per worktree**, tracked by ID, so renames and Rex server restarts don't break the link.
- **Per-repo layouts**: tabs, panes and commands (e.g. agent, `npm install` + shell, dev server).
- **Installed agents only**: Lanes offers the agents Rex supports that are on your `PATH`.
- **Any branch**: local, remote-only (Lanes creates a tracking branch), or new.

## Requirements

| Tool                                      | Tested with                     |
| ----------------------------------------- | ------------------------------- |
| [Rex](https://www.superlogical.com/)      | Mac app, October 2026 previews¹ |
| [WorkTrunk](https://worktrunk.dev) (`wt`) | 0.81.0²                         |
| [fzf](https://github.com/junegunn/fzf)    | 0.74.5                          |
| [jq](https://jqlang.org)                  | 1.7.1                           |
| git, bash                                 | bash 3.2 (macOS default)        |

¹ Sessions survive server restarts from preview.23. ² Lanes requires schema 2 of `wt list --format=json`.

Turn on **Rex → Settings → Rex Server → Remote Control** so Lanes can switch the app to the new session. Without it, open the session from the sidebar.

## Install

```sh
git clone https://github.com/tsyirvo/rex-lanes ~/.config/rex/lanes
cp ~/.config/rex/lanes/layouts.example.lua ~/.config/rex/lanes-layouts.lua
```

Add to `~/.config/rex/init.lua`:

```lua
require("lanes").setup{ layouts = require("lanes-layouts") }

rex.bind("cmd+alt+n", "lanes_new")
rex.bind("cmd+alt+backspace", "lanes_remove")
```

Then run `rex config reload`. With `XDG_CONFIG_HOME` set, use `$XDG_CONFIG_HOME/rex` instead of `~/.config/rex`.

## Use

Focus a pane in a git repo.

**`lanes_new`** ("Lanes: New Worktree…"): type a branch name and press Return, then pick an agent or "terminal only". An existing worktree opens its session; any other name creates a worktree, checking out an existing branch or branching from the default branch. Return on an empty query opens the highlighted worktree; Alt-Return does so even with text typed.

**`lanes_remove`** ("Lanes: Remove Worktree…"): pick a worktree (the preview shows status and recent commits). WorkTrunk removes it, refusing uncommitted changes and keeping unmerged branches, and Lanes closes its session.

## Configure

```lua
require("lanes").setup{
  -- Agent commands to offer; first is the default. Omit to use the agents
  -- Rex supports. Either way, only those on PATH are shown.
  agents = { "claude", "codex --full-auto" },

  -- Modal x, y, width, height as fractions of the window.
  bounds = { 0.2, 0.15, 0.6, 0.6 },

  -- Session layouts per repo.
  layouts = require("lanes-layouts"),
}
```

### Layouts

The first layout whose `repo` matches applies, else the first `repo = "*"`, else a default of agent tab + shell tab.

```lua
return {
  {
    repo = "my-app",
    tabs = {
      { name = "agent", agent = true },
      { name = "terminal", panes = {
        { command = "npm install" },
        { split = "right" },
      } },
      { name = "dev", command = "npm run dev" },
    },
  },
}
```

| Field     | On        | Meaning                                                                                       |
| --------- | --------- | --------------------------------------------------------------------------------------------- |
| `repo`    | layout    | Repo name on its forge or folder name (case-insensitive), the main checkout's path, or `"*"`. |
| `name`    | tab       | Tab label.                                                                                    |
| `agent`   | tab       | `true` to run the chosen agent. Skipped for "terminal only".                                  |
| `command` | tab, pane | Typed into the shell; the prompt stays after it ends.                                         |
| `panes`   | tab       | List of panes instead of one shell.                                                           |
| `cwd`     | tab, pane | Start directory, relative to the worktree (tab) or tab (pane). Absolute and `~` paths work.   |
| `split`   | pane      | `"right"` or `"down"` (default) relative to the previous pane. Not set on the first pane.     |
| `ratio`   | pane      | Share of the split, between 0 and 1 (default 0.5).                                            |

A tab has at most one of `agent`, `command` or `panes`. `command` and `cwd` can be functions that receive the worktree (`path`, `branch`, `main`, `repo`) and return a string; `nil` or `""` gives a plain shell. See [`layouts.example.lua`](layouts.example.lua).

Config errors don't break the rest of your `init.lua`; Lanes reports them, with their location, when you run one of its actions.

## How it works

Rex actions can't read input and must finish within 30 seconds, so `lanes_new` and `lanes_remove` only open a floating terminal running `modal.sh`. It runs the fzf pickers and `wt`, then calls back with `rex do lanes_open` / `lanes_close`, targeting the app that opened it. `init.lua` then finds or builds the session and switches to it.

Session IDs are stored in `$XDG_STATE_HOME/rex/lanes.json` (default `~/.local/state/rex/lanes.json`); stale entries are dropped. Session labels (`repo/branch`) are display-only.

## Develop

```sh
mise install      # Lua 5.1.5, shellcheck, hk, gitleaks
hk install        # git hooks
mise run check    # shellcheck, bash 3.2 syntax check, Lua tests
```

Commits follow [Conventional Commits](https://www.conventionalcommits.org) and PRs are squash-merged. [release-please](https://github.com/googleapis/release-please) maintains a release PR; merging it tags and publishes the release.

## License

[MIT](LICENSE)
