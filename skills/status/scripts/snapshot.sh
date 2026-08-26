#!/usr/bin/env bash
# Emit a concise, read-only orientation snapshot for /gantry:status.
# Never modifies anything. Output is plain labeled sections meant to be
# read by Claude and synthesized into a short report — not shown verbatim.
set -uo pipefail

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "NOT_A_GIT_REPO"
  echo "cwd: $(pwd)"
  exit 0
fi

GIT_COMMON="$(git rev-parse --path-format=absolute --git-common-dir)"
MAIN_ROOT="$(dirname "$GIT_COMMON")"
TOPLEVEL="$(git rev-parse --show-toplevel)"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '(detached)')"
[ "$TOPLEVEL" != "$MAIN_ROOT" ] && IS_WORKTREE="yes" || IS_WORKTREE="no"

echo "== LOCATION =="
echo "cwd:       $(pwd)"
echo "toplevel:  $TOPLEVEL"
echo "main_root: $MAIN_ROOT"
echo "worktree:  $IS_WORKTREE"
echo "branch:    $BRANCH"

echo
echo "== SYNC =="
UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
if [ -n "$UPSTREAM" ]; then
  read -r BEHIND AHEAD < <(git rev-list --left-right --count '@{u}...HEAD' 2>/dev/null || echo "0 0")
  echo "upstream:  $UPSTREAM"
  echo "behind:    ${BEHIND:-0}"
  echo "ahead:     ${AHEAD:-0}"
else
  echo "upstream:  (none)"
fi

# Base branch for "what's on this branch" — prefer the remote's default, then
# common names. Used only to bound the commit list below.
BASE=""
DEF="$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's#refs/remotes/origin/##')"
for cand in "$DEF" develop main master; do
  [ -z "$cand" ] && continue
  if git show-ref --verify --quiet "refs/heads/$cand" \
     || git show-ref --verify --quiet "refs/remotes/origin/$cand"; then
    BASE="$cand"; break
  fi
done

echo
echo "== WORKING TREE =="
PORC="$(git status --porcelain 2>/dev/null)"
if [ -z "$PORC" ]; then
  echo "clean:     yes"
else
  echo "clean:     no"
  echo "staged:    $(git diff --cached --name-only  | grep -c . )"
  echo "unstaged:  $(git diff --name-only           | grep -c . )"
  echo "untracked: $(git ls-files --others --exclude-standard | grep -c . )"
  echo "-- changed files (git status --short) --"
  git status --short
fi

echo
echo "== RECENT COMMITS (this branch tip) =="
git log -n 8 --format='%h %s (%cr)' 2>/dev/null || echo "(none)"

if [ -n "$BASE" ] && [ "$BRANCH" != "$BASE" ]; then
  echo
  echo "== COMMITS ON $BRANCH SINCE $BASE =="
  MB="$(git merge-base HEAD "$BASE" 2>/dev/null || git merge-base HEAD "origin/$BASE" 2>/dev/null || true)"
  if [ -n "$MB" ]; then
    N="$(git rev-list --count "$MB"..HEAD 2>/dev/null || echo 0)"
    echo "count:     $N"
    git log "$MB"..HEAD --format='%h %s (%cr)' 2>/dev/null
  else
    echo "(no common ancestor with $BASE found)"
  fi
fi

echo
echo "== PLAN / DOC FILES =="
# Surface likely plan/intent files at the repo root and one level down.
FOUND=""
while IFS= read -r f; do
  [ -n "$f" ] && { echo "$f"; FOUND="yes"; }
done < <(cd "$TOPLEVEL" 2>/dev/null && \
  git ls-files 2>/dev/null | grep -iE '(^|/)(plan|todo|roadmap|tasks|notes)[^/]*\.(md|txt)$|(^|/)CLAUDE\.md$' | head -30)
[ -z "$FOUND" ] && echo "(none tracked)"

exit 0
