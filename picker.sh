#!/usr/bin/env bash
#
# The new-worktree picker. init.lua puts this text before modal.sh, and only
# functions and constants are defined here.
#
#   pick_branch BASE WORKTREES HIDDEN   print the chosen branch, or fail on cancel
#   branch_kind NAME                    print invalid, worktree, local, remote or new
#   picker_incompatibility              print why this fzf can't run the picker, if so
#
# BASE is what a new branch starts from. WORKTREES has one line per worktree,
# with its branch and displayed path as the first two tab-separated fields.
# HIDDEN is a branch to leave out of the lists, though it can still be typed.

FZF_LOOK=(--reverse --info=inline --height=100% --border=none)

# Older versions run the picker but flatten its headings into the rows.
PICKER_MIN_FZF=0.71.0

picker_incompatibility() {
  local version oldest
  version=$(fzf --version)
  version=${version%% *}
  oldest=$(printf '%s\n' "$PICKER_MIN_FZF" "$version" | sort -t. -k1,1n -k2,2n -k3,3n | head -n1)
  [[ $oldest == "$PICKER_MIN_FZF" ]] || echo "Lanes needs fzf $PICKER_MIN_FZF or newer, but this fzf is $version."
}

branch_kind() {
  local name=$1
  if ! git check-ref-format --branch "$name" >/dev/null 2>&1; then
    echo invalid
  elif git show-ref --quiet --verify "refs/heads/$name"; then
    if [[ -n $(git for-each-ref --format='%(worktreepath)' "refs/heads/$name") ]]; then
      echo worktree
    else
      echo local
    fi
  elif [[ -n $(git for-each-ref --count=1 --format=x "refs/remotes/*/$name") ]]; then
    echo remote
  else
    echo new
  fi
}

# lstrip=2, not refname:short: a tag with the same name makes the short form
# heads/NAME, which is not the branch's name.
branches_without_worktree() {
  git for-each-ref refs/heads --sort=-committerdate \
    --format='%(refname:lstrip=2)%09%(worktreepath)%09%(committerdate:relative) · %(subject)' \
    | awk -F'\t' '$2 == "" { print $1 "\t" $3 }'
}

without_branch() { awk -F'\t' -v branch="$1" '$1 != branch'; }

picker_section() {
  local kind=$1 marker=$2 width=$3 name detail
  while IFS=$'\t' read -r name detail; do
    printf '%s\t%s\t\t%s\t%-*s\t%s\0' "$name" "$kind" "$marker" "$width" "$name" "$detail"
  done
}

picker_rows() {
  local hidden_branch=$2 dim=$'\033[2m' reset=$'\033[0m' worktrees branches width
  worktrees=$(cut -f1,2 <<<"$1" | without_branch "$hidden_branch")
  branches=$(branches_without_worktree | without_branch "$hidden_branch")
  width=$(printf '%s\n%s\n' "$worktrees" "$branches" \
    | awk -F'\t' 'length($1) > longest { longest = length($1) } END { print longest + 2 }')

  if [[ -n $worktrees ]]; then
    printf '\theading\t%s\t\t\t\0' "${dim}WORKTREES${reset}"
    picker_section worktree '●' "$width" <<<"$worktrees"
  fi
  if [[ -n $branches ]]; then
    local gap=
    [[ -z $worktrees ]] || gap=$'\n'
    printf '\theading\t%s\t\t\t\0' "$gap${dim}BRANCHES without a worktree${reset}"
    picker_section branch '○' "$width" <<<"$branches"
  fi
}

# fzf has no unfocusable rows, so the cursor passes over a heading in the
# direction it was moving. Printed for fzf to run as an action.
step_over_heading() {
  [[ $1 == heading ]] || return 0
  if [[ $FZF_ACTION == *up* && $FZF_POS -gt 1 ]]; then echo up; else echo down; fi
}

# What Return will do, shown as the picker's footer. fzf runs this in a child
# shell, which reads the base from PICKER_BASE.
describe_return() {
  local query=$1 highlighted=$2 highlighted_kind=$3 action
  if [[ -z $query ]]; then
    case $highlighted_kind in
      worktree) echo "↵ open $highlighted" ;;
      branch) echo "↵ new worktree on existing branch $highlighted" ;;
      *) echo "Type a branch name" ;;
    esac
    return
  fi

  case $(branch_kind "$query") in
    invalid) action="Not a valid branch name" ;;
    worktree) action="↵ open $query" ;;
    local) action="↵ new worktree on existing branch $query" ;;
    remote) action="↵ new worktree tracking remote branch $query" ;;
    new) action="↵ create new branch $query from $PICKER_BASE" ;;
  esac
  if [[ -n $highlighted && $highlighted != "$query" ]]; then
    action+="  ·  alt-↵ use $highlighted"
  fi
  echo "$action"
}

pick_branch() {
  local base=$1 worktrees=$2 hidden_branch=$3 tab=$'\t' dim=$'\033[2m' reset=$'\033[0m' out status query key highlighted

  # Bash builds differ in how they export functions, so the footer's shell has
  # to be this same bash.
  export -f branch_kind describe_return step_over_heading

  # Field 3 of a row is a heading's text, field 5 a padded name. --nth=2 searches
  # only names, and a heading has none, so typing hides the headings.
  #
  # scroll-up and scroll-down are bound so that the mouse wheel names a direction
  # in FZF_ACTION, for step_over_heading.
  #
  # A process substitution, not a pipe: with pipefail, fzf exiting before all
  # rows are written would look like a cancel.
  out=$(PICKER_BASE=$base fzf "${FZF_LOOK[@]}" --read0 --ansi --no-sort --tabstop=2 \
      --delimiter="$tab" --with-nth="{3}{4}$tab{5}$tab$dim{6}$reset" --nth=2 --accept-nth=1 \
      --print-query --expect=alt-enter --prompt='new worktree ❯ ' \
      --with-shell="$BASH -c" \
      --bind='scroll-up:up,scroll-down:down' \
      --bind='start,result,focus:transform(step_over_heading {2})+transform-footer(describe_return {q} {1} {2})' \
      < <(picker_rows "$worktrees" "$hidden_branch"))
  status=$?
  [[ $status -gt 1 ]] && return 1
  { IFS= read -r query; IFS= read -r key; IFS= read -r highlighted; } <<<"$out"

  if [[ -n $highlighted && ( $key == alt-enter || -z $query ) ]]; then
    printf '%s' "$highlighted"
  elif [[ -n $query ]]; then
    printf '%s' "$query"
  else
    return 1
  fi
}
