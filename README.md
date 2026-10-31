# Lanes

Lanes gives each git worktree its own [Rex](https://www.superlogical.com/rex) session, with a coding agent in it.

Press a key, type a branch name, and pick an agent. Lanes makes the worktree with [WorkTrunk](https://worktrunk.dev) and runs its hooks where you can see them. It then opens a session for the worktree with the tabs and panes you set for that repo. Press another key to remove the worktree. Its session closes with it.

- **One session per worktree.** Lanes remembers each worktree's session by its ID. Renaming a session does not break the link, and the link survives a Rex server restart.
- **Layouts per repo.** Set the tabs, the panes and the commands for each repo: an agent in one tab, `npm install` beside a free shell in the next, a dev server in a third.
- **Only the agents that work here.** Lanes asks Rex which agents it supports and offers the ones installed on your machine.
- **Branches from anywhere.** Type a local branch, a branch that is only on a remote (Lanes makes a tracking branch), or a new name.

## Requirements

| Tool                                      | Tested with                    | Notes                                                                                         |
| ----------------------------------------- | ------------------------------ | --------------------------------------------------------------------------------------------- |
| [Rex](https://www.superlogical.com/rex)   | Mac app, October 2026 previews | Sessions, and so Lanes' links to them, survive server restarts from preview.23.               |
| [WorkTrunk](https://worktrunk.dev) (`wt`) | 0.81.0                         | Lanes reads schema 2 of `wt list --format=json` and stops with a message on any other schema. |
| [fzf](https://github.com/junegunn/fzf)    | 0.74.5                         |                                                                                               |
| [jq](https://jqlang.org)                  | 1.7.1                          |                                                                                               |
| git, bash                                 | bash 3.2                       | Works with the bash that macOS ships.                                                         |

**Remote Control.** Lanes switches the app to the new session from a script. Rex accepts that only when Remote Control is on: Rex → Settings → Rex Server → Remote Control. Without it, Lanes still creates the session, and you open it from the sidebar.

## Install

1. Clone Lanes into your Rex configuration folder:

   ```sh
   git clone https://github.com/tsyirvo/rex-lanes ~/.config/rex/lanes
   ```

2. Copy the example layouts beside it:

   ```sh
   cp ~/.config/rex/lanes/layouts.example.lua ~/.config/rex/lanes-layouts.lua
   ```

3. Add Lanes to `~/.config/rex/init.lua`:

   ```lua
   require("lanes").setup{ layouts = require("lanes-layouts") }

   rex.bind("cmd+alt+n", "lanes_new")
   rex.bind("cmd+alt+backspace", "lanes_remove")
   ```

4. Reload the configuration:

   ```sh
   rex config reload
   ```

If you keep your configuration somewhere else with `XDG_CONFIG_HOME`, use `$XDG_CONFIG_HOME/rex` in place of `~/.config/rex`.

## Use

Focus a pane in a git repository.

**New worktree** (`lanes_new`, "Lanes: New Worktree…" in the command palette):

1. Lanes lists the repo's worktrees.
2. Type a branch name and press Return.
   - An existing worktree opens its session. Lanes asks for an agent only when it must build that session.
   - Any other name gets a new worktree. A branch that exists here or on a remote is checked out. Any other name becomes a new branch from the default branch.
3. Pick an agent, or "terminal only".

Press Return with nothing typed to open the highlighted worktree. Press Alt-Return to open the highlighted worktree even when you typed something.

**Remove worktree** (`lanes_remove`, "Lanes: Remove Worktree…"):

1. Pick a worktree. The preview shows its status and its last commits.
2. WorkTrunk removes it. WorkTrunk refuses a worktree with uncommitted changes, and keeps a branch that is not merged.
3. Lanes closes the worktree's session. If you ran the modal from inside that session, Lanes first moves you to the main checkout's session.

## Configure

`setup` takes three options:

```lua
require("lanes").setup{
  -- Agent commands to offer. Leave it out to ask Rex for the agents it
  -- supports. Either way, Lanes offers only those whose program is on PATH,
  -- then "terminal only". The first one is the default.
  agents = { "claude", "codex --full-auto" },

  -- The modal's x, y, width and height, as fractions of the window.
  bounds = { 0.2, 0.15, 0.6, 0.6 },

  -- The tabs and panes of a new session, per repo.
  layouts = require("lanes-layouts"),
}
```

### Agents

When you leave out `agents`, Lanes runs `rex skill status --json` and uses the agents Rex supports, in Rex's order. Today these are Claude Code (`claude`), Codex (`codex`), OpenCode (`opencode`) and Pi (`pi`). Lanes then keeps only the agents whose program it finds on your `PATH`. Rex can report an agent as found from its configuration folder alone, so this second check hides an agent that you uninstalled.

A command in your own `agents` list can have arguments. Lanes checks only its first word against `PATH`.

### Layouts

A layout names a repo and lists the tabs a new session opens with. The first layout that matches the repo applies, else the first `repo = "*"` layout, else the default: the agent in one tab and a shell in a second tab.

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

| Field     | On        | Meaning                                                                                                                                                         |
| --------- | --------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `repo`    | layout    | The repo's name on its forge, or its folder name, compared without case. Or the main checkout's path (`~` allowed), compared exactly. `"*"` matches every repo. |
| `name`    | tab       | The tab's label.                                                                                                                                                |
| `agent`   | tab       | `true`: the tab runs the agent you pick. Lanes leaves the tab out when you pick "terminal only".                                                                |
| `command` | tab, pane | Text typed into the shell. When the command ends, the shell prompt stays.                                                                                       |
| `panes`   | tab       | A list of panes in place of one shell.                                                                                                                          |
| `cwd`     | tab, pane | Where the shell starts. A tab's `cwd` is relative to the worktree, and a pane's is relative to its tab. Absolute and `~` paths also work.                       |
| `split`   | pane      | `"right"` (beside) or `"down"` (below, the default) the pane before it. The first pane has none.                                                                |
| `ratio`   | pane      | The share of the split the pane takes, more than 0 and less than 1. The default is 0.5. The panes after it share the same part.                                 |

A tab has at most one of `agent`, `command` and `panes`. `command` and `cwd` can also be a function that gets the worktree (`path`, `branch`, `main`, `repo`) and returns a string. A function that returns `nil` or `""` gives a plain shell. [`layouts.example.lua`](layouts.example.lua) has a function that picks `bun install` or `npm install` from the lock file it finds.

Lanes checks the options and the layouts when Rex loads them. A mistake, such as an unknown field or `split = "left"`, does not stop the rest of your `init.lua`. Lanes reports it when you run `lanes_new` or `lanes_remove`, with its place:

```
lanes: fix the setup in init.lua: layouts[1].tabs[2].panes[2].split: expected "right" or "down", got left
```

## How it works

```
lanes_new (key or palette)
  init.lua opens a floating terminal over the window, running modal.sh
    modal.sh: fzf pickers, then `wt switch` (hooks run here, in view)
    rex -C <your app> do lanes_open path=… branch=… agent=…
      init.lua finds the worktree's session, or builds it from the layout
      the app switches to it
```

An action in Rex cannot read input, and it must finish within 30 seconds. So `lanes_new` and `lanes_remove` only open the modal and return. The modal sends its result back with `rex do` to two internal actions, `lanes_open` and `lanes_close`. It passes the ID of the app that opened it, so on a machine with several Rex apps connected, the right app switches.

Lanes keeps each worktree's session ID in `$XDG_STATE_HOME/rex/lanes.json` (`~/.local/state/rex/lanes.json` by default). It drops an entry when its session no longer exists. A session's label is `repo/branch`, cut to Rex's 128-character limit. The label is for display only, so you and your agents can rename sessions.

## Develop

```sh
mise install      # Lua 5.1.5, shellcheck, hk and gitleaks
hk install        # git hooks: secret scan, checks and tests on commit, commit message format
mise run check    # shellcheck, a bash 3.2 syntax check, and the Lua tests
```

The tests cover `layout.lua`: layout matching, the tabs and panes built from a layout, labels, and the layout checks. Rex runs Lua 5.1, so the tests do too. To try a change in Rex without touching your loaded configuration, run `rex config check` on an `init.lua` that requires your working copy.

### Commits and releases

Commit messages follow [Conventional Commits](https://www.conventionalcommits.org): `feat: …`, `fix: …`, `docs: …`, and `!` after the type for a breaking change. The `commit-msg` hook checks each message. PRs are squash-merged, so the PR title becomes the commit on `main`, and CI checks the title too.

[release-please](https://github.com/googleapis/release-please) reads those commits. It keeps a release PR open with the next version and the new `CHANGELOG.md` entries. Merge that PR to release: release-please then tags `vX.Y.Z` and publishes the GitHub release. Before 1.0.0, a `feat` or a breaking change bumps the minor version, and a `fix` bumps the patch version.

## License

[MIT](LICENSE)
