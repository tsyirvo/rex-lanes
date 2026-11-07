#!/usr/bin/env bash
#
# Tests for the modal, with real git and wt, a fake rex and a scripted fzf. Run
# from the repo root:
#
#   /bin/bash tests/modal_test.sh

set -uo pipefail

ROOT=$PWD
ORIGINAL_HOME=$HOME ORIGINAL_PATH=$PATH
command -v fzf >/dev/null || { echo "fzf not found on PATH"; exit 1; }
command -v wt >/dev/null || { echo "wt not found on PATH"; exit 1; }
command -v jq >/dev/null || { echo "jq not found on PATH"; exit 1; }

WORK=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$WORK"' EXIT

# Nothing from the machine's git or wt configuration may reach a test, nor the
# repo-specific variables that git sets for its hooks, such as GIT_INDEX_FILE.
# shellcheck disable=SC2046 # one variable name per word
unset $(git rev-parse --local-env-vars)
export HOME=$WORK/home XDG_CONFIG_HOME=$WORK/home/.config
export GIT_CONFIG_GLOBAL=$WORK/home/.gitconfig GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
mkdir -p "$HOME" "$WORK/bin"

# A scripted fzf: it records its options and rows, and answers from FAKE_*.
cat >"$WORK/bin/fzf" <<'FAKE'
#!/usr/bin/env bash
if [[ ${1-} == --version ]]; then echo "${FAKE_FZF_VERSION:-0.74.5} (fake)"; exit 0; fi
case "$*" in
  *--print-query*) picker=branch ;;
  *"remove worktree"*) picker=remove ;;
  *) picker=agent ;;
esac
printf '%s\n' "$@" >"$FAKE_DIR/$picker.options"
cat >"$FAKE_DIR/$picker.rows"
case $picker in
  branch)
    printf '%s\n%s\n%s\n' "${FAKE_QUERY-}" "${FAKE_KEY-}" "${FAKE_HIGHLIGHTED-}"
    [[ ${FAKE_STATUS:-0} == 0 ]] || exit "$FAKE_STATUS"
    [[ -n ${FAKE_HIGHLIGHTED-} ]] ;;
  remove) exit 130 ;;
  agent) printf '\tterminal only\n' ;;
esac
FAKE

cat >"$WORK/bin/rex" <<'FAKE'
#!/usr/bin/env bash
case "$1 ${2-}" in
  "client ls"|"client inspect") exit 0 ;;
  "skill status") echo '{}'; exit 0 ;;
esac
cat >/dev/null
echo "$*" >>"$FAKE_DIR/rex.log"
echo '{}'
FAKE
chmod +x "$WORK/bin/fzf" "$WORK/bin/rex"
export PATH=$WORK/bin:$PATH

passed=0 failed=0 sequence=0

fail() { echo "    $*"; exit 1; }
eq() { [[ $1 == "$2" ]] || fail "${3-value}: expected [$2], got [$1]"; }
has() { [[ $1 == *"$2"* ]] || fail "${3-value}: expected [$2] in [$1]"; }
lacks() { [[ $1 != *"$2"* ]] || fail "${3-value}: unexpected [$2] in [$1]"; }

test_case() {
  sequence=$((sequence + 1))
  local dir=$WORK/$sequence
  mkdir -p "$dir/fake"
  export FAKE_DIR=$dir/fake
  REPO=$dir/repo
  if (
    git init -q -b main "$REPO" && cd "$REPO" && git commit -q --allow-empty -m init || exit 1
    "$2"
  ); then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    echo "FAIL: $1"
  fi
}

# Runs the modal from directory FROM (default: the repo). Sets MODAL_STATUS and
# MODAL_OUTPUT. The text is put together as init.lua does.
run_modal() {
  local mode=$1 from=${2-$REPO}
  MODAL_OUTPUT=$(cd "$from" && "$BASH" -c "$(cat "$ROOT/picker.sh" "$ROOT/modal.sh")" \
    lanes "$mode" "" BUNDLE rex </dev/null 2>&1)
  MODAL_STATUS=$?
}

# Types NAME and presses Return, in the new-worktree modal.
create() {
  local name=$1 from=${2-$REPO}
  FAKE_QUERY=$name run_modal new "$from"
  eq "$MODAL_STATUS" 0 "modal status, output: $MODAL_OUTPUT"
}

worktree_of() { echo "$REPO.${1//\//-}"; }
head_of() { git -C "$1" rev-parse HEAD; }
worktree_count() { git -C "$REPO" worktree list | wc -l | tr -d ' '; }
rex_calls() { cat "$FAKE_DIR/rex.log" 2>/dev/null; }

commit_on() {
  git -C "$REPO" switch -q -c "$1" && git -C "$REPO" commit -q --allow-empty -m "${2-work on $1}"
  git -C "$REPO" switch -q main
}

# The picker's branch names, in order. A row starts with its name, and a heading
# has none.
listed_names() {
  local row
  while IFS= read -r -d '' row; do
    [[ $row == $'\t'* ]] || echo "${row%%$'\t'*}"
  done <"$FAKE_DIR/$1.rows"
}

picker_text() { tr '\0' '\n' <"$FAKE_DIR/branch.rows"; }

open_picker() { FAKE_STATUS=130 run_modal new; }

# What real fzf finds for QUERY, given the options and rows the picker used. The
# original environment matters: a version manager's fzf shim would otherwise
# find the fake one on PATH.
search() {
  local options=() option
  while IFS= read -r option; do options+=("$option"); done <"$FAKE_DIR/branch.options"
  HOME=$ORIGINAL_HOME PATH=$ORIGINAL_PATH fzf "${options[@]}" --filter="$1" <"$FAKE_DIR/branch.rows" | sed 1d | sed '/^$/d' | paste -sd, -
}

# Importing an existing branch

imports_a_branch_with_commits() {
  commit_on has-work
  local before; before=$(git rev-parse has-work)
  create has-work
  eq "$(head_of "$(worktree_of has-work)")" "$before" "worktree head"
  eq "$(git rev-parse has-work)" "$before" "branch"
  has "$(rex_calls)" "branch=has-work" "session"
  lacks "$MODAL_OUTPUT" "--create" "wt call"
}

imports_an_empty_branch_without_moving_it() {
  git branch empty
  git commit -q --allow-empty -m "main moves on"
  local before; before=$(git rev-parse empty)
  create empty
  eq "$(head_of "$(worktree_of empty)")" "$before" "worktree head"
}

imports_a_branch_with_a_slash() {
  commit_on feature/slashed
  create feature/slashed
  eq "$(git -C "$(worktree_of feature/slashed)" branch --show-current)" feature/slashed
}

imports_without_using_the_focused_pane_as_a_base() {
  git commit -q --allow-empty -m second
  git branch older HEAD~1
  git worktree add -q -b other "$REPO.other"
  git -C "$REPO.other" commit -q --allow-empty -m "on other"
  create older "$REPO.other"
  eq "$(head_of "$(worktree_of older)")" "$(git rev-parse main~1)" "worktree head"
}

tracks_a_remote_only_branch() {
  git init -q --bare "$REPO.origin"
  git remote add origin "$REPO.origin"
  commit_on remote-only
  git push -q origin remote-only
  git branch -qD remote-only
  git fetch -q origin
  create remote-only
  eq "$(git -C "$(worktree_of remote-only)" rev-parse --abbrev-ref '@{upstream}')" origin/remote-only
}

refuses_a_folder_that_is_in_the_way() {
  git branch blocked
  mkdir "$(worktree_of blocked)"
  echo keep >"$(worktree_of blocked)/file"
  FAKE_QUERY=blocked run_modal new
  eq "$MODAL_STATUS" 1 "modal status"
  has "$MODAL_OUTPUT" "wt switch failed"
  eq "$(cat "$(worktree_of blocked)/file")" keep "the folder's file"
  eq "$(rex_calls)" "" "rex calls"
}

# Choosing with the keyboard

creates_a_new_branch_from_the_focused_pane() {
  git worktree add -q -b other "$REPO.other"
  git -C "$REPO.other" commit -q --allow-empty -m "on other"
  create stacked "$REPO.other"
  eq "$(head_of "$(worktree_of stacked)")" "$(git rev-parse other)" "worktree head"
}

return_on_an_empty_query_uses_the_highlighted_branch() {
  commit_on highlighted
  FAKE_HIGHLIGHTED=highlighted run_modal new
  eq "$(git -C "$(worktree_of highlighted)" branch --show-current)" highlighted
}

return_on_a_partial_name_creates_that_name() {
  commit_on feat/payments
  FAKE_QUERY=pay FAKE_HIGHLIGHTED=feat/payments run_modal new
  eq "$(git -C "$(worktree_of pay)" branch --show-current)" pay
  eq "$(worktree_count)" 2 "worktrees"
}

alt_return_uses_the_highlighted_branch_despite_the_query() {
  commit_on feat/payments
  FAKE_QUERY=pay FAKE_KEY=alt-enter FAKE_HIGHLIGHTED=feat/payments run_modal new
  eq "$(git -C "$(worktree_of feat/payments)" branch --show-current)" feat/payments
  eq "$(worktree_count)" 2 "worktrees"
}

an_existing_worktree_opens_without_asking_for_an_agent() {
  git worktree add -q -b other "$REPO.other"
  create other
  eq "$(worktree_count)" 2 "worktrees"
  has "$(rex_calls)" "branch=other" "session"
  lacks "$(rex_calls)" "agent=" "session"
  [[ ! -e $FAKE_DIR/agent.options ]] || fail "asked for an agent"
}

cancelling_changes_nothing() {
  commit_on untouched
  FAKE_STATUS=130 FAKE_QUERY=typed run_modal new
  eq "$MODAL_STATUS" 0 "modal status"
  eq "$(worktree_count)" 1 "worktrees"
  eq "$(rex_calls)" "" "rex calls"
}

an_invalid_name_is_refused() {
  FAKE_QUERY='not..valid' run_modal new
  eq "$MODAL_STATUS" 1 "modal status"
  has "$MODAL_OUTPUT" "Not a valid branch name: not..valid"
}

# What the picker lists

lists_worktrees_then_branches_without_a_worktree() {
  git worktree add -q -b attached "$REPO.attached"
  GIT_COMMITTER_DATE="2020-01-01T00:00:00" commit_on a-older
  GIT_COMMITTER_DATE="2021-01-01T00:00:00" commit_on z-newer
  open_picker
  eq "$(listed_names branch | paste -sd, -)" attached,z-newer,a-older "rows"
}

heads_each_section_once() {
  commit_on one
  commit_on two
  git worktree add -q -b attached "$REPO.attached"
  open_picker
  local rows; rows=$(picker_text)
  eq "$(grep -c WORKTREES <<<"$rows")" 1 "worktree headings"
  eq "$(grep -c 'BRANCHES without a worktree' <<<"$rows")" 1 "branch headings"
}

omits_the_heading_of_an_empty_section() {
  open_picker
  lacks "$(picker_text)" WORKTREES "rows"
  lacks "$(picker_text)" BRANCHES "rows"
}

separates_sections_with_a_blank_line_only_between_them() {
  commit_on no-worktree
  open_picker
  lacks "$(picker_text)" $'\n\033[2mBRANCHES' "branches alone"
  git worktree add -q -b attached "$REPO.attached"
  open_picker
  has "$(picker_text)" $'\n\033[2mBRANCHES' "both sections"
}

leaves_the_default_branch_out_of_the_worktrees() {
  git worktree add -q -b attached "$REPO.attached"
  open_picker
  eq "$(listed_names branch)" attached "rows"
}

leaves_the_default_branch_out_of_the_branches() {
  git switch -q -c elsewhere
  open_picker
  eq "$(listed_names branch)" elsewhere "rows"
}

finds_the_default_branch_whatever_its_name() {
  git branch trunk
  wt config state default-branch set trunk >/dev/null 2>&1
  open_picker
  eq "$(listed_names branch)" main "rows"
}

typing_the_default_branch_still_opens_it() {
  create main
  has "$(rex_calls)" "branch=main" "session"
  eq "$(worktree_count)" 1 "worktrees"
}

lists_a_branch_by_its_name_when_a_tag_shares_it() {
  commit_on shared
  git tag shared shared
  open_picker
  eq "$(listed_names branch | paste -sd, -)" shared "rows"
}

search_matches_names_in_both_sections() {
  git worktree add -q -b feat/auth "$REPO.feat-auth"
  commit_on feat/payments "commit subject"
  commit_on other-branch
  open_picker
  eq "$(search feat)" feat/auth,feat/payments "feat"
  eq "$(search pay)" feat/payments "pay"
}

search_ignores_headings_paths_and_subjects() {
  commit_on feat/payments "commit subject"
  open_picker
  eq "$(search payments)" feat/payments "a name"
  eq "$(search BRANCHES)" "" "heading"
  eq "$(search WORKTREES)" "" "heading"
  eq "$(search subject)" "" "commit subject"
  eq "$(search repo)" "" "path"
}

the_remove_picker_lists_only_worktrees() {
  git worktree add -q -b attached "$REPO.attached"
  commit_on no-worktree
  run_modal remove
  has "$(cat "$FAKE_DIR/remove.rows")" attached "rows"
  lacks "$(cat "$FAKE_DIR/remove.rows")" no-worktree "rows"
}

# The footer and the fzf version

describes_what_return_will_do() {
  commit_on local-branch
  git worktree add -q -b attached "$REPO.attached"
  git update-ref refs/remotes/origin/remote-branch HEAD
  # shellcheck disable=SC1091
  source "$ROOT/picker.sh"
  export PICKER_BASE=main
  eq "$(describe_return '' attached worktree)" "↵ open attached"
  eq "$(describe_return '' local-branch local)" "↵ new worktree on existing branch local-branch"
  eq "$(describe_return '' '' '')" "Type a branch name"
  eq "$(describe_return attached attached worktree)" "↵ open attached"
  eq "$(describe_return local-branch local-branch local)" "↵ new worktree on existing branch local-branch"
  eq "$(describe_return remote-branch '' '')" "↵ new worktree tracking remote branch remote-branch"
  eq "$(describe_return fresh '' '')" "↵ create new branch fresh from main"
  eq "$(describe_return loc local-branch local)" "↵ create new branch loc from main  ·  alt-↵ use local-branch"
  eq "$(describe_return 'not..valid' '' '')" "Not a valid branch name"
}

steps_over_headings_in_the_direction_of_travel() {
  # shellcheck disable=SC1091
  source "$ROOT/picker.sh"
  eq "$(FZF_ACTION=up FZF_POS=5 step_over_heading heading)" up "moving up"
  eq "$(FZF_ACTION=page-up FZF_POS=5 step_over_heading heading)" up "paging up"
  eq "$(FZF_ACTION=down FZF_POS=5 step_over_heading heading)" down "moving down"
  eq "$(FZF_ACTION=up FZF_POS=1 step_over_heading heading)" down "at the top"
  eq "$(FZF_ACTION=mouse FZF_POS=1 step_over_heading heading)" down "after a reset"
  eq "$(FZF_ACTION=up FZF_POS=5 step_over_heading local)" "" "on a row"
}

explains_an_fzf_that_is_too_old() {
  FAKE_FZF_VERSION=0.70.9 FAKE_QUERY=anything run_modal new
  eq "$MODAL_STATUS" 1 "modal status"
  has "$MODAL_OUTPUT" "Lanes needs fzf 0.71.0 or newer, but this fzf is 0.70.9."
  eq "$(worktree_count)" 1 "worktrees"
}

compares_fzf_versions_as_numbers() {
  # shellcheck disable=SC1091
  source "$ROOT/picker.sh"
  # shellcheck disable=SC2329 # fzf_version_problem calls it
  fzf() { echo "$FAKE_FZF_VERSION (fake)"; }
  FAKE_FZF_VERSION=0.100.0
  eq "$(fzf_version_problem)" "" "0.100.0"
  FAKE_FZF_VERSION=0.71.0
  eq "$(fzf_version_problem)" "" "0.71.0"
}

for name in \
  imports_a_branch_with_commits \
  imports_an_empty_branch_without_moving_it \
  imports_a_branch_with_a_slash \
  imports_without_using_the_focused_pane_as_a_base \
  tracks_a_remote_only_branch \
  refuses_a_folder_that_is_in_the_way \
  creates_a_new_branch_from_the_focused_pane \
  return_on_an_empty_query_uses_the_highlighted_branch \
  return_on_a_partial_name_creates_that_name \
  alt_return_uses_the_highlighted_branch_despite_the_query \
  an_existing_worktree_opens_without_asking_for_an_agent \
  cancelling_changes_nothing \
  an_invalid_name_is_refused \
  lists_worktrees_then_branches_without_a_worktree \
  heads_each_section_once \
  omits_the_heading_of_an_empty_section \
  separates_sections_with_a_blank_line_only_between_them \
  leaves_the_default_branch_out_of_the_worktrees \
  leaves_the_default_branch_out_of_the_branches \
  finds_the_default_branch_whatever_its_name \
  typing_the_default_branch_still_opens_it \
  steps_over_headings_in_the_direction_of_travel \
  lists_a_branch_by_its_name_when_a_tag_shares_it \
  search_matches_names_in_both_sections \
  search_ignores_headings_paths_and_subjects \
  the_remove_picker_lists_only_worktrees \
  describes_what_return_will_do \
  explains_an_fzf_that_is_too_old \
  compares_fzf_versions_as_numbers
do
  test_case "$name" "$name"
done

echo "$passed passed, $failed failed"
[[ $failed -eq 0 ]]
