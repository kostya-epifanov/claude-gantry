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
#
# `set -e` is deliberately absent: every labeled line below must print even when
# a step fails, so lib/session_paths.sh — which this sources for the slug
# convention — defines functions and sets no shell options of its own.
set -uo pipefail

# THE SOURCE IS THE ONE EXCEPTION to "print the lines anyway". Without `-e`,
# bash carries on past a failed `.` in a non-interactive script: `slugify` and
# `sessions_dir` are then undefined, `DIR` is empty, and this prints
# `DOC=/<date>-session.md` — the filesystem ROOT — and exits 0. A caller
# parsing that would have gantry:preserve write outside any sessions directory.
# A missing lib makes every line below untrustworthy, so it is fatal.
GANTRY="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=../../../lib/session_paths.sh
. "$GANTRY/lib/session_paths.sh" || {
  printf 'doc_path: could not source %s/lib/session_paths.sh\n' "$GANTRY" >&2
  exit 2
}

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  MAIN_ROOT="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
  BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo detached)"
else
  MAIN_ROOT="$(pwd)"
  BRANCH="(no repo)"
fi

RAW="${1:-}"
[ -z "$RAW" ] && RAW="$BRANCH"
[ "$RAW" = "HEAD" ] && RAW="detached"
SLUG="$(slugify "$RAW")"
[ -z "$SLUG" ] && SLUG="session"

DIR="$(sessions_dir "$MAIN_ROOT")"
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
