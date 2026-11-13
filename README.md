# Lanes

Lanes gives each git worktree its own [Rex](https://www.superlogical.com/) session, or a tab in the one you are in, with a coding agent in it.

Press a key, type a branch, pick an agent. Lanes creates the worktree with [WorkTrunk](https://worktrunk.dev), runs its hooks in view, and opens a session (or, with `open = "tab"`, a tab) laid out the way you set for that repo. Press another key to remove the worktree and close its session or tab.

- **One session or tab per worktree**, tracked by ID, so renames don't break the link. A worktree that already has either opens there, whatever `open` says now.
- **Per-repo layouts**: tabs, panes and commands (e.g. agent, `npm install` + shell, dev server).
- **Installed agents only**: Lanes offers the agents Rex supports that are on your `PATH`.
- **Any branch**: pick a local branch from the list to give it a worktree, type a remote-only one (Lanes creates a tracking branch), or type a new one, built on the branch you're on.

## Requirements

| Tool                                      | Tested with                     |
| ----------------------------------------- | ------------------------------- |
| [Rex](https://www.superlogical.com/)      | Mac app, October 2026 previews¹ |
| [WorkTrunk](https://worktrunk.dev) (`wt`) | 0.81.0²                         |
| [fzf](https://github.com/junegunn/fzf)    | 0.74.5 (needs 0.71.0 or newer)  |
| [jq](https://jqlang.org)                  | 1.7.1                           |
| git, bash                                 | bash 3.2 (macOS default)        |

¹ Sessions survive server restarts from preview.23. Tab IDs may not: after a restart Lanes forgets a tab, but removing the worktree still closes it when every pane in the tab is in that worktree. ² Lanes requires schema 2 of `wt list --format=json`.

Install Lanes on the Mac only. It also works in sessions on remote hosts, which need no copy of it, but `wt`, `fzf`, `jq`, `git`, `bash` and `rex` must be on the `PATH` of the machine the pane runs on.

Turn on **Rex → Settings → Rex Server → Remote Control** so Lanes can switch the app to a new session. Without it, open the session from the sidebar. A new tab needs no switching: it opens active in the session you are in.

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

**`lanes_new`** ("Lanes: New Worktree…"): the picker lists your worktrees (`●`) and, below them, local branches without a worktree (`○`), most recently committed first. The default branch isn't listed, but typing its name still works. Search matches names only, and worktrees stay above branches while you filter. The line at the bottom says what Return will do.

- Return on an empty query uses the highlighted row. Alt-Return does so even with text typed.
- Return with text typed uses exactly that name: a worktree opens its session or tab, or any tab with a pane in it; a local or remote-only branch gets a new worktree, with its commits untouched; any other name becomes a new branch from what the focused pane has checked out (its branch, or its commit on a detached HEAD), so running it from a worktree stacks the new branch on top.

A new worktree then asks for an agent or "terminal only". In tab mode the tab opens in the session you ran `lanes_new` from, labelled with the branch.

**`lanes_remove`** ("Lanes: Remove Worktree…"): pick a worktree (the preview shows status and recent commits). WorkTrunk removes it, refusing uncommitted changes and keeping unmerged branches, and Lanes closes its session or tab. If you were in that session, Lanes takes you to a session with a pane in the main checkout (whatever branch it's on), else to the next session in the list. It never creates a session here. A session that also holds other worktrees' tabs is kept: only the removed worktree's tabs close. A tab that is the last one of its session closes the session.

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

  -- "session" (default): a new worktree gets a session of its own.
  -- "tab": it gets one tab, with any panes, in the session you opened the
  -- modal from. Existing sessions and tabs are found whichever you pick.
  open = "session",
}
```

### Layouts

The first layout whose `repo` matches applies, else the first `repo = "*"`, else a default of agent tab + shell tab (in tab mode, one tab with the agent beside a shell).

A layout has `tabs` (used when `open = "session"`), `tab` (used when `open = "tab"`), or both, so one layout serves both modes. In tab mode a layout without `tab` doesn't take part: a repo's `tabs`-only layout is skipped, and the first `"*"` layout with a `tab` applies instead.

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
| `tabs`    | layout    | Tabs of a new session, in order.                                                              |
| `tab`     | layout    | The one tab of a new worktree in tab mode. Labelled with the branch, so it has no `name`.     |
| `name`    | tab       | Tab label (in `tabs`).                                                                        |
| `agent`   | tab, pane | `true` to run the chosen agent. See below for "terminal only".                                |
| `command` | tab, pane | Typed into the shell; the prompt stays after it ends.                                         |
| `panes`   | tab       | List of panes instead of one shell.                                                           |
| `cwd`     | tab, pane | Start directory, relative to the worktree (tab) or tab (pane). Absolute and `~` paths work.   |
| `split`   | pane      | `"right"` or `"down"` (default) relative to the previous pane. Not set on the first pane.     |
| `ratio`   | pane      | Share of the split, between 0 and 1 (default 0.5).                                            |

A tab has at most one of `agent`, `command` or `panes`, and a pane at most one of `agent` or `command`. With "terminal only", an `agent` tab in `tabs` is left out, while an `agent` pane (and a `tab` that is itself `agent = true`) becomes a plain shell, so the layout you drew stays whole. `command` and `cwd` can be functions that receive the worktree (`path`, `branch`, `main`, `repo`) and return a string; `nil` or `""` gives a plain shell. See [`layouts.example.lua`](layouts.example.lua).

Config errors don't break the rest of your `init.lua`; Lanes reports them, with their location, when you run one of its actions.

Keep layouts that use functions in their own file, loaded with `require`, because Lanes sends that file's text to the machine the worktree is on. Functions run there, so they see that machine's files. A layouts file that requires another file needs it on that machine too.

## How it works

Rex actions can't read input and must finish within 30 seconds, so `lanes_new` and `lanes_remove` only open a floating terminal running `modal.sh` and its picker, `picker.sh`. It runs the fzf pickers and `wt`, then runs `lanes_open` / `lanes_close` with `rex do`, which find or build the session or tab and switch the app to it.

Actions run on the Mac, even when the pane is on a remote host, and `rex.exec` can only start programs on the Mac. So Lanes looks for the repository through the pane, and gives the floating terminal the text of those scripts and of a bundle holding its Lua and your layouts. `lanes_open` and `lanes_close` come from that bundle, so they run on the pane's machine.

Session IDs, and for a tab its session and window ID, are stored in `$XDG_STATE_HOME/rex/lanes.json` (default `~/.local/state/rex/lanes.json`) on the machine that has the worktree; stale entries are dropped. Labels (`repo/branch` for a session, the branch for a tab) are display-only.

## Develop

```sh
mise install      # Lua 5.1.5, shellcheck, hk, gitleaks
hk install        # git hooks
mise run check    # shellcheck, bash 3.2 syntax check, Lua tests
```

Commits follow [Conventional Commits](https://www.conventionalcommits.org) and PRs are squash-merged. [release-please](https://github.com/googleapis/release-please) maintains a release PR; merging it tags and publishes the release.

## License

[MIT](LICENSE)
