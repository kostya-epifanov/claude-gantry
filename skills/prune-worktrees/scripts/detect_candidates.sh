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
#     path|branch|status|days_idle|merged_into|head_sha
#   status:      main | current | bare | locked | dirty | candidate | keep
#   merged_into: comma-separated base names (develop,master,main) or -
set -euo pipefail

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

path="" branch="" locked=0 bare=0 headsha=""

emit() {
  [ -z "$path" ] && return
  if [ "$bare" = "1" ]; then
    echo "$path|-|bare|-|-|-"
    return
  fi

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

  echo "$path|${branch:--}|$status|$days_idle|$merged_into|${headsha:0:8}"
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
