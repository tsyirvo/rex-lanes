#!/usr/bin/env bash
#
# The worktree modal. init.lua runs it in a floating terminal whose
# working directory is the repo to act on.
#
#   modal.sh new CLIENT rex             list worktrees, type a branch name, pick an
#   modal.sh new CLIENT list AGENT...   agent, create or open its session
#   modal.sh remove CLIENT              pick a worktree, `wt remove` it, close its session
#
# CLIENT is the Rex client that opened the modal, "" when unknown. Results go
# back to it with `rex -C CLIENT do lanes_open` / `lanes_close`. The agents
# offered are the ones Rex supports (rex) or the given commands (list), each
# only when its program is on PATH, then "terminal only".
#
# Kept to bash 3.2, the one macOS ships: an empty array is never expanded.

set -uo pipefail

dim()  { printf '\033[2m%s\033[0m\n' "$*"; }
hold() { printf '\n\033[31m%s\033[0m\n\033[2mpress any key to close\033[0m' "$*"; read -rsn1; exit 1; }

for tool in wt fzf jq git rex; do
  command -v "$tool" >/dev/null 2>&1 || hold "$tool not found on PATH"
done
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || hold "not a git repository: $PWD"

# shellcheck disable=SC2054 # --with-nth=1,2 is one argument
FZF_OPTS=(--reverse --info=inline --height=100% --border=none --delimiter=$'\t' --with-nth=1,2)
CLIENT=
AGENT_SOURCE=rex
AGENT_LIST=()

# The `wt list --format=json` layout this script reads.
WT_SCHEMA=2

rexdo() { rex ${CLIENT:+-C "$CLIENT"} "do" "$@"; }

# Reads the repo with one `wt list`. Sets ITEMS, one line per worktree: branch,
# path (with ~), "main" or "", absolute path. Sets MAIN to the main checkout's
# path, and REPO to the forge's name for the repo ("" without a forge).
load() {
  local json
  json=$(command wt list --format=json 2>/dev/null) || hold "wt list failed"
  local schema
  schema=$(jq -r '.schema // "none"' <<<"$json")
  [[ $schema == "$WT_SCHEMA" ]] \
    || hold "Lanes reads schema $WT_SCHEMA of wt list's JSON, but this wt prints schema $schema. Update Lanes or WorkTrunk."
  ITEMS=$(jq -r --arg home "$HOME" '
    .items[] | select(.worktree != null and .branch != null)
    | [.branch, (.worktree.path | sub("^" + $home; "~")),
       (if .worktree.main then "main" else "" end), .worktree.path]
    | @tsv' <<<"$json")
  REPO=$(jq -r '.repo.forge.name // empty' <<<"$json")
  MAIN=$(awk -F'\t' '$3 == "main" { print $4; exit }' <<<"$ITEMS")
}

path_of() { awk -F'\t' -v b="$1" '$1 == b { print $4; exit }' <<<"$ITEMS"; }

# The agent commands to offer, one per line: the agents Rex supports, or the
# configured list, each only when its program is on PATH. Rex names an agent
# by its command (claude, codex, opencode, pi). A name that is not a command
# fails the PATH check and is left out, so it can never be offered broken.
agents() {
  local a
  if [[ $AGENT_SOURCE == rex ]]; then
    rex skill status --json 2>/dev/null | jq -r '.harnesses[]?.id' 2>/dev/null
  else
    for a in ${AGENT_LIST[@]+"${AGENT_LIST[@]}"}; do printf '%s\n' "$a"; done
  fi | while IFS= read -r a; do
    if [[ -n $a ]] && command -v "${a%% *}" >/dev/null 2>&1; then printf '%s\n' "$a"; fi
  done
}

pick_agent() {
  local name=$1 choice
  choice=$({ agents | awk '{ print $0 "\t" }'; printf '\tterminal only\n'; } \
    | fzf "${FZF_OPTS[@]}" --no-sort \
      --prompt='agent ❯ ' \
      --header="Agent for $name · ↵ pick · esc cancel") || return 1
  printf '%s' "${choice%%$'\t'*}"
}

# Opens the session for a worktree. Without an agent, a missing session comes
# back as needs_agent: ask for one, then try again with it ("" = none).
open_session() {
  local path=$1 name=$2 out agent
  local args=(lanes_open "path=$path" "branch=$name" "main=$MAIN" "repo=$REPO")
  [[ $# -gt 2 ]] && args+=("agent=$3")
  out=$(rexdo "${args[@]}") || hold "Could not switch to the session for $name (see above).
If the session is in the sidebar, turn on Rex → Settings → Rex Server → Remote Control to switch to it automatically."
  if jq -e '.needs_agent == true' >/dev/null 2>&1 <<<"$out"; then
    agent=$(pick_agent "$name") || exit 0
    open_session "$path" "$name" "$agent"
  fi
}

new() {
  local out query key sel name path agent create
  load

  # Enter takes the typed name exactly (existing → open, new → create); with
  # nothing typed it opens the highlighted worktree. alt-enter opens the
  # highlighted one even when something is typed.
  out=$(fzf "${FZF_OPTS[@]}" --print-query --expect=alt-enter \
      --prompt='new worktree ❯ ' \
      --header=$'Type a branch name · ↵ create (or open if it exists) · alt-↵ open highlighted · esc cancel' \
      <<<"$ITEMS")
  [[ $? -gt 1 ]] && exit 0
  { IFS= read -r query; IFS= read -r key; IFS= read -r sel; } <<<"$out"

  if [[ $key == alt-enter && -n $sel ]] || [[ -z $query && -n $sel ]]; then
    name=${sel%%$'\t'*}
  else
    name=$query
  fi
  [[ -z $name ]] && exit 0

  path=$(path_of "$name")
  if [[ -n $path ]]; then
    # Existing worktree: switch to its session. An agent is asked for only
    # when the session has to be built.
    open_session "$path" "$name"
    return
  fi

  git check-ref-format --branch "$name" >/dev/null 2>&1 || hold "Not a valid branch name: $name"
  agent=$(pick_agent "$name") || exit 0

  # A branch that exists here or on a remote is checked out, and wt makes a
  # tracking branch for a remote one. Any other name is a new branch.
  create=--create
  if git show-ref --quiet --verify "refs/heads/$name" \
    || [[ -n $(git for-each-ref --count=1 --format=x "refs/remotes/*/$name") ]]; then
    create=
  fi

  # Hooks run here, where their output is visible: wt prints them on stderr
  # and only the JSON result on stdout. --no-cd: this shell is not the one
  # that will live in the worktree.
  dim "wt switch${create:+ $create} $name"
  out=$(command wt switch ${create:+"$create"} "$name" --no-cd --format=json) \
    || hold "wt switch failed (see above)"
  path=$(jq -r '.path // empty' <<<"$out")
  [[ -n $path ]] || hold "WorkTrunk reported no worktree for $name"
  open_session "$path" "$name" "$agent"
}

remove() {
  local cands sel name path
  load
  cands=$(awk -F'\t' '$3 != "main"' <<<"$ITEMS")
  [[ -n $cands ]] || { dim "No worktrees to remove besides the main checkout."; sleep 1.5; exit 0; }

  sel=$(fzf "${FZF_OPTS[@]}" \
      --prompt='remove worktree ❯ ' \
      --header='↵ remove · refused with uncommitted changes · an unmerged branch is kept · esc cancel' \
      --preview='git -C {4} -c color.status=always status --short --branch; echo; git -C {4} log --oneline --color=always -8' \
      --preview-window=down,50% \
      <<<"$cands") || exit 0
  name=${sel%%$'\t'*}
  path=$(path_of "$name")

  # -C main: wt never has to move this shell out of the worktree it deletes.
  # Without --foreground, wt runs its checks and hooks here, moves the worktree
  # to its trash and returns; freeing the disk space carries on in the
  # background, so nobody waits for it. wt says itself when it keeps a branch.
  dim "wt remove $name"
  command wt remove -C "$MAIN" "$name" || hold "wt remove failed (see above)"

  # Shown before the session closes: the modal may live in that session.
  printf '\n\033[32m✓ Removed %s\033[0m\n' "$name"
  sleep 1

  rexdo lanes_close "path=$path" "branch=$name" "main=$MAIN" "repo=$REPO" >/dev/null \
    || hold "Removed $name, but could not close its Rex session"
}

case ${1-} in
  new)
    CLIENT=${2-} AGENT_SOURCE=${3-rex}
    shift $(($# < 3 ? $# : 3))
    AGENT_LIST=("$@")
    new ;;
  remove) CLIENT=${2-}; remove ;;
  *)      hold "usage: modal.sh new CLIENT rex | new CLIENT list AGENT... | remove CLIENT" ;;
esac
