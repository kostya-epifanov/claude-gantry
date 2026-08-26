#!/usr/bin/env bash
# Resolve the handoff document's path for /gantry:preserve, deterministically.
#
# Same day + same slug => same path, which is what makes the skill idempotent:
# a second run in one session updates the first run's file instead of adding
# a new one. The slug is the optional label argument, else the current branch.
#
# Docs live under ~/.claude/sessions/<repo-path-slug>/, NOT inside the repo:
#   - a worktree-isolated session cannot write to the main checkout at all
#   - worktrees get pruned, and a note that dies with its worktree is worthless
#   - nothing outside the repo can be swept into a commit by accident
# The repo slug mirrors Claude Code's own project-dir convention (absolute path
# with "/" replaced by "-"), so a repo's notes sit beside its auto-memory.
# Emits labeled KEY=value lines.
set -uo pipefail

slugify() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9]\+/-/g' -e 's/^-\+//' -e 's/-\+$//' \
    | cut -c1-48
}

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  MAIN_ROOT="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
  BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo detached)"
else
  MAIN_ROOT="$(pwd)"
  BRANCH="(no repo)"
fi

REPO_SLUG="$(printf '%s' "$MAIN_ROOT" | sed 's#/#-#g')"

RAW="${1:-}"
[ -z "$RAW" ] && RAW="$BRANCH"
[ "$RAW" = "HEAD" ] && RAW="detached"
SLUG="$(slugify "$RAW")"
[ -z "$SLUG" ] && SLUG="session"

DIR="$HOME/.claude/sessions/$REPO_SLUG"
DOC="$DIR/$(date +%F)-$SLUG.md"

mkdir -p "$DIR"

echo "DOC=$DOC"
echo "REPO=$MAIN_ROOT"
echo "BRANCH=$BRANCH"
echo "SLUG=$SLUG"
[ -f "$DOC" ] && echo "EXISTS=yes" || echo "EXISTS=no"

# Other recent handoff docs for this repo, newest first — context for whether
# this continues earlier work. Excludes the target itself.
echo "== RECENT =="
# shellcheck disable=SC2010  # sorting by mtime is the point; -t has no glob equivalent
ls -t "$DIR"/*.md 2>/dev/null | grep -vxF "$DOC" | head -5 || true
