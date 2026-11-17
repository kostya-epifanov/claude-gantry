#!/usr/bin/env bash
# detect_candidates.sh — enumerate worktrees and classify each as a prune
# candidate, keep, or skip (locked/dirty/main/current), for /gantry:prune-worktrees.
# Read-only except for `git fetch origin --prune` on the main repo.
#
# Run with: bash detect_candidates.sh   (from anywhere inside the repo/worktree)
#
# stdout:
#   FETCH:ok            or   FETCH:failed
#   one line per worktree, pipe-delimited:
#     path|branch|status|days_idle|merged_into|head_sha|artifacts
#   status:      main | current | bare | locked | dirty | candidate | keep
#   merged_into: comma-separated base names (develop,master,main) or -. When no
#                base matches but the head is an ancestor of an origin/integration/*
#                branch, those branches are named instead (`integration/<name>`).
#   artifacts:   comma-separated chain artifacts the worktree holds, `-` for
#                none, `?` when the worktree could not be read
#
# WHY `artifacts` IS NOT PART OF `status`. The chain's artifacts are excluded
# from git, and `git status --porcelain` — the call that decides `dirty` below —
# cannot see an excluded file. That is the whole reason this field exists; it is
# read from the filesystem by lib/worktree_artifacts.sh instead. It is REPORTED
# and never classified: every gantry worktree holds artifacts, so folding them
# into `dirty` would make the prune skill inert.
set -euo pipefail

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/lib"

MAIN_ROOT="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
CURRENT_WT="$(git rev-parse --show-toplevel)"
STALE_DAYS=7
NOW=$(date +%s)

if git -C "$MAIN_ROOT" fetch origin --prune >/dev/null 2>&1; then
  echo "FETCH:ok"
else
  echo "FETCH:failed"
fi

BASES=()
BASE_LABELS=()
for name in develop master main; do
  if git -C "$MAIN_ROOT" show-ref --verify --quiet "refs/remotes/origin/$name"; then
    BASES+=("refs/remotes/origin/$name"); BASE_LABELS+=("$name")
  elif git -C "$MAIN_ROOT" show-ref --verify --quiet "refs/heads/$name"; then
    BASES+=("refs/heads/$name"); BASE_LABELS+=("$name")
  fi
done

# origin/integration/* branches (gantry:integrate's lanes). A head merged into one
# counts as merged: the branch stays on origin, so a dropped integration can be
# checked out again. Kept apart from BASES so the integration names only show up
# when no develop/master/main matched (every older head is an ancestor of every
# later integration cut from the base, and would otherwise flood the field).
INTEG_REFS=()
INTEG_LABELS=()
while IFS= read -r ref; do
  [ -n "$ref" ] || continue
  INTEG_REFS+=("$ref"); INTEG_LABELS+=("${ref#refs/remotes/origin/}")
done < <(git -C "$MAIN_ROOT" for-each-ref --format='%(refname)' refs/remotes/origin/integration/ 2>/dev/null)

path="" branch="" locked=0 bare=0 headsha=""

emit() {
  [ -z "$path" ] && return
  if [ "$bare" = "1" ]; then
    echo "$path|-|bare|-|-|-|-"
    return
  fi

  # `|| echo '?'` is load-bearing under `set -e`: a command substitution that
  # exits non-zero terminates this whole script, so a worktree git still lists
  # but whose directory is gone would truncate the row stream at that line — and
  # a caller would bucket a partial candidate list without ever knowing. `?`
  # (could not be read) is deliberately NOT `-` (holds nothing); flattening the
  # two is how a truncation becomes invisible.
  local artifacts
  artifacts="$(bash "$LIB/worktree_artifacts.sh" "$path" 2>/dev/null || echo '?')"
  [ -n "$artifacts" ] || artifacts='?'

  local status="" ref_for_check="$branch"
  [ -z "$branch" ] && ref_for_check="$headsha"

  if [ "$path" = "$MAIN_ROOT" ]; then status="main"
  elif [ "$path" = "$CURRENT_WT" ]; then status="current"
  elif [ "$locked" = "1" ]; then status="locked"
  elif [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]; then status="dirty"
  fi

  local tip_epoch days_idle merged=() merged_into="-"
  tip_epoch=$(git -C "$MAIN_ROOT" log -1 --format=%ct "$ref_for_check" 2>/dev/null || echo "$NOW")
  days_idle=$(( (NOW - tip_epoch) / 86400 ))
  for i in "${!BASES[@]}"; do
    if git -C "$MAIN_ROOT" merge-base --is-ancestor "$ref_for_check" "${BASES[$i]}" 2>/dev/null; then
      merged+=("${BASE_LABELS[$i]}")
    fi
  done
  if [ ${#merged[@]} -eq 0 ] && [ ${#INTEG_REFS[@]} -gt 0 ]; then
    for i in "${!INTEG_REFS[@]}"; do
      # A lane's own pushed branch is not "merged" — its PR is still open.
      [ "${INTEG_LABELS[$i]}" = "$branch" ] && continue
      # A detached lane worktree has no branch name; its head is the pushed tip.
      [ -z "$branch" ] && [ "$(git -C "$MAIN_ROOT" rev-parse "${INTEG_REFS[$i]}" 2>/dev/null)" = "$headsha" ] && continue
      if git -C "$MAIN_ROOT" merge-base --is-ancestor "$ref_for_check" "${INTEG_REFS[$i]}" 2>/dev/null; then
        merged+=("${INTEG_LABELS[$i]}")
      fi
    done
  fi
  if [ ${#merged[@]} -gt 0 ]; then
    local IFS=,; merged_into="${merged[*]}"; unset IFS
  fi

  if [ -z "$status" ]; then
    if [ "$days_idle" -ge "$STALE_DAYS" ] || [ "$merged_into" != "-" ]; then
      status="candidate"
    else
      status="keep"
    fi
  fi

  echo "$path|${branch:--}|$status|$days_idle|$merged_into|${headsha:0:8}|$artifacts"
}

while IFS= read -r line; do
  case "$line" in
    "worktree "*) emit; path="${line#worktree }"; branch=""; locked=0; bare=0; headsha="" ;;
    "HEAD "*)     headsha="${line#HEAD }" ;;
    "branch "*)   branch="${line#branch refs/heads/}" ;;
    "locked"*)    locked=1 ;;
    "bare")       bare=1 ;;
    *)            : ;;
  esac
done < <(git -C "$MAIN_ROOT" worktree list --porcelain)
emit
