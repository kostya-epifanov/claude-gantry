#!/usr/bin/env bash
# detect_state.sh — read-only snapshot of where a branch is on the ship path
# (commit -> push -> open PR -> wait), for /gantry:ship.
#
# Read-only: runs only `git` queries and `gh pr view` (a read). Modifies nothing.
# Run with: bash detect_state.sh   (from anywhere inside the repo/worktree)
#
# stdout — labeled lines, then one STAGE line:
#   BRANCH:<name>              or  DETACHED  (and STAGE:detached)
#   BASE:<default-branch>      the repo's default branch (PR base)
#   UPSTREAM:<ref>             or  NONE
#   AHEAD:<n>  BEHIND:<n>       vs upstream (0 0 when UPSTREAM:NONE)
#   AHEAD_OF_BASE:<n>          commits on this branch not in BASE
#   DIRTY:clean                or  DIRTY:staged=<n> unstaged=<n> untracked=<n>
#   ON_DEFAULT:yes|no          on the repo default branch (can't PR against itself)
#   GH:ok|missing|unauth
#   PR:none                    or  PR:<number> <url> <state> <mergeable> <reviewDecision>
#   STAGE:<on-default|commit|push|behind|pr|no-diff|done|detached|not-a-repo>
#
# Optional: --base <branch> overrides base detection (must name a branch that
# exists on origin or locally, else it's ignored and detection runs).
set -uo pipefail

BASE_OVERRIDE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --base)   [ $# -ge 2 ] || { echo "detect_state: --base needs a branch" >&2; exit 2; }
              BASE_OVERRIDE="$2"; shift 2 ;;
    --base=*) BASE_OVERRIDE="${1#--base=}"; shift ;;
    *)        echo "detect_state: unknown argument: $1" >&2; exit 2 ;;
  esac
done

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "STAGE:not-a-repo"; exit 0; }

BRANCH="$(git symbolic-ref --quiet --short HEAD || true)"
if [ -z "$BRANCH" ]; then echo "DETACHED"; echo "STAGE:detached"; exit 0; fi
echo "BRANCH:$BRANCH"

# Default branch (PR base). Resolution order — kept in step with gantry:worktree so the
# branch a worktree is cut from and the base a PR targets never disagree:
#   1. an explicit --base <branch>, if it validates;
#   2. develop, if it exists on origin or locally (many repos integrate there, and
#      that's where their PRs go even when the remote default is main/master) —
#      but NOT when you're on develop yourself, since a branch can't PR into itself;
#      then it falls through so develop can ship into main/master;
#   3. origin/HEAD, the remote's declared default — but only if it still resolves.
#      origin/HEAD can be STALE, naming a branch the remote no longer has; trusting
#      it blindly makes `gh pr create --base <that>` fail with "Base ref must be a
#      branch", so verify the remote-tracking ref exists before believing it.
#   4. the first of main/master that exists, else "main".
base_exists() { git show-ref --verify --quiet "refs/remotes/origin/$1" || git show-ref --verify --quiet "refs/heads/$1"; }
BASE=""
if [ -n "$BASE_OVERRIDE" ]; then
  if base_exists "$BASE_OVERRIDE"; then BASE="$BASE_OVERRIDE"
  else echo "detect_state: --base '$BASE_OVERRIDE' not found on origin or locally; auto-detecting instead" >&2; fi
fi
[ -z "$BASE" ] && [ "$BRANCH" != "develop" ] && base_exists develop && BASE="develop"
if [ -z "$BASE" ]; then
  cand="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
  [ -n "$cand" ] && git show-ref --verify --quiet "refs/remotes/origin/$cand" && BASE="$cand"
fi
if [ -z "$BASE" ]; then
  for c in main master; do
    if base_exists "$c"; then BASE="$c"; break; fi
  done
fi
[ -z "$BASE" ] && BASE="main"
echo "BASE:$BASE"

# Upstream tracking ref + ahead/behind.
UPSTREAM="$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)"
AHEAD=0; BEHIND=0
if [ -n "$UPSTREAM" ]; then
  echo "UPSTREAM:$UPSTREAM"
  read -r BEHIND AHEAD < <(git rev-list --left-right --count "$UPSTREAM...HEAD" 2>/dev/null || echo "0 0")
else
  echo "UPSTREAM:NONE"
fi
echo "AHEAD:$AHEAD  BEHIND:$BEHIND"

# Commits on this branch not yet in the base (is there anything to PR?).
AOB=0
if git rev-parse --verify --quiet "refs/remotes/origin/$BASE" >/dev/null 2>&1; then
  AOB="$(git rev-list --count "origin/$BASE..HEAD" 2>/dev/null || echo 0)"
elif git rev-parse --verify --quiet "refs/heads/$BASE" >/dev/null 2>&1; then
  AOB="$(git rev-list --count "$BASE..HEAD" 2>/dev/null || echo 0)"
fi
echo "AHEAD_OF_BASE:$AOB"

# Working-tree state.
STAGED=0; UNSTAGED=0; UNTRACKED=0
while IFS= read -r line; do
  [ -z "$line" ] && continue
  x="${line:0:1}"; y="${line:1:1}"
  if [ "$x$y" = "??" ]; then UNTRACKED=$((UNTRACKED+1)); continue; fi
  [ "$x" != " " ] && STAGED=$((STAGED+1))
  [ "$y" != " " ] && UNSTAGED=$((UNSTAGED+1))
done < <(git status --porcelain)
DIRTY_TOTAL=$((STAGED+UNSTAGED+UNTRACKED))
if [ "$DIRTY_TOTAL" -eq 0 ]; then echo "DIRTY:clean"; else echo "DIRTY:staged=$STAGED unstaged=$UNSTAGED untracked=$UNTRACKED"; fi

# On a branch you must not commit onto / can't PR from: the chosen BASE (can't PR
# into itself) OR a real mainline. Checking only BASE would miss the case where
# BASE resolved to develop but you're sitting on main — ship must still refuse there.
ON_DEFAULT=no
DEFAULT_REMOTE="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
for prot in "$BASE" "$DEFAULT_REMOTE" main master; do
  [ -n "$prot" ] && [ "$BRANCH" = "$prot" ] && { ON_DEFAULT=yes; break; }
done
echo "ON_DEFAULT:$ON_DEFAULT"

# gh availability + existing PR for this branch.
GH=ok; PR="none"
if ! command -v gh >/dev/null 2>&1; then
  GH=missing
elif ! gh auth status >/dev/null 2>&1; then
  GH=unauth
else
  PRJSON="$(gh pr view --json number,url,state,mergeable,reviewDecision 2>/dev/null || true)"
  if [ -n "$PRJSON" ]; then
    PR="$(printf '%s' "$PRJSON" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d["number"], d["url"], d["state"], d.get("mergeable") or "UNKNOWN", d.get("reviewDecision") or "NONE")' 2>/dev/null || true)"
    [ -z "$PR" ] && PR="none"
  fi
fi
echo "GH:$GH"
echo "PR:$PR"

# Decide the entry stage.
if [ "$ON_DEFAULT" = yes ]; then
  STAGE="on-default"
elif [ "$DIRTY_TOTAL" -gt 0 ]; then
  STAGE="commit"
elif [ "$BEHIND" -gt 0 ] && [ "$AHEAD" -gt 0 ]; then
  STAGE="behind"
elif [ "$UPSTREAM" = "" ] || [ "$AHEAD" -gt 0 ]; then
  STAGE="push"
elif [ "$PR" = none ]; then
  if [ "$AOB" -gt 0 ]; then STAGE="pr"; else STAGE="no-diff"; fi
else
  STAGE="done"
fi
echo "STAGE:$STAGE"
