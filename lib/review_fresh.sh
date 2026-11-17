#!/usr/bin/env bash
# review_fresh.sh — does review.md still describe this branch and this diff?
# Run with: bash review_fresh.sh [--findings] [path/to/review.md]
#   (default file: review.md at the repository root; run from inside the repo/worktree)
#
# WHY THIS EXISTS. gantry:review --fix refuses findings written for a different
# diff, and gantry:ship quotes review.md's Risk level into the PR. Both need the
# same answer to "is this review about the tree I am holding?", so it is one
# script rather than two paragraphs of prose that can drift. A stale review
# counts as a missing one: ship publishes `unassessed`.
#
# It compares review.md's `branch:` with the current branch, and the recorded
# token with `diff_fingerprint.sh <base:>`. The recorded token is, by default,
# the `diff=` on the `applied:` line when there is one (the tree as the fix step
# left it), else `diff:`. With --findings it is always `diff:` — what the apply
# step needs, so a second --fix on an already-fixed tree is refused.
#
# stdout: FRESH:yes|stale|absent|error, then REASON:<one line>.
# Exit: 0 fresh · 1 stale · 3 no review.md · 2 unreadable, malformed, base does
# not resolve, not a repo, or usage.
set -uo pipefail

FINDINGS=0
FILE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --findings) FINDINGS=1 ;;
    -*) printf 'FRESH:error\nREASON:unknown option %s\n' "$1"; exit 2 ;;
    *) [ -z "$FILE" ] || { printf 'FRESH:error\nREASON:more than one review file given\n'; exit 2; }; FILE="$1" ;;
  esac
  shift
done

out() { printf 'FRESH:%s\nREASON:%s\n' "$1" "$2"; exit "$3"; }

HERE="$(cd "$(dirname "$0")" && pwd)"
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || out error "not inside a git repository" 2
ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || out error "could not resolve the repository root" 2
[ -n "$FILE" ] || FILE="$ROOT/review.md"
[ -e "$FILE" ] || out absent "no review.md" 3
[ -r "$FILE" ] || out error "review.md is not readable" 2

field() { sed -n "s/^$1:[[:space:]]*//p" "$FILE" | head -1 | tr -d '\r'; }
R_BRANCH="$(field branch)"
R_BASE="$(field base)"
R_DIFF="$(field diff)"
[ -n "$R_BRANCH" ] && [ -n "$R_BASE" ] && [ -n "$R_DIFF" ] \
  || out error "review.md lacks a branch:, base: or diff: line" 2

if [ "$FINDINGS" -eq 0 ]; then
  # the applied: line is the file's last non-blank line; a pre-diff= line falls back to diff:
  # (the LAST non-blank line, as detect_stage.sh defines it — not any mid-file match)
  APPLIED="$(grep -v '^[[:space:]]*$' "$FILE" | tail -1 | sed -n 's/^applied:.*[[:space:]]diff=\([0-9a-fA-F][0-9a-fA-F]*\).*/\1/p')"
  [ -z "$APPLIED" ] || R_DIFF="$APPLIED"
fi

CUR_BRANCH="$(cd "$ROOT" && git rev-parse --abbrev-ref HEAD 2>/dev/null)"
[ "$CUR_BRANCH" = "$R_BRANCH" ] || out stale "review.md is for branch $R_BRANCH, this is $CUR_BRANCH" 1

TOKEN="$(cd "$ROOT" && bash "$HERE/diff_fingerprint.sh" "$R_BASE" 2>/dev/null)" \
  || out error "diff_fingerprint.sh failed for base $R_BASE" 2
[ "$TOKEN" = "$R_DIFF" ] || out stale "the diff moved since review.md was written" 1
out yes "branch and diff match review.md" 0
