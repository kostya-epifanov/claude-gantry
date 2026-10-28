#!/usr/bin/env bash
# archive_artifacts.sh — copy a worktree's chain artifacts out of the repo
# BEFORE anything removes the worktree.
# Run with: bash archive_artifacts.sh <worktree-path> <branch> <head-sha>
#
# WHY THIS EXISTS. `git worktree remove` deletes an excluded file silently (see
# lib/worktree_artifacts.sh for the mechanism), and `handover.md` is the one
# that hurts: it records what a change deliberately did not do, and its only
# other route to a human is gantry:ship quoting it into the pull request body.
# A handover written after the PR opened reaches nobody, and the worktree
# holding the only copy is one merge away from being pruned. So prune copies
# first and destroys second, and this is the copy.
#
# WHERE IT LANDS.
#
#   ~/.claude/sessions/<repo-slug>/worktrees/<YYYY-MM-DD>-<branch-slug>-<sha8>/
#
# Under the directory gantry:preserve already owns for the same reason — it is
# outside every repo, so no worktree prune can reach it and no `git add -A` can
# sweep it into a commit. lib/session_paths.sh holds the convention so the two
# cannot drift apart.
#
# The directory is REUSED, not uniquified, when it already exists, and a second
# run overwrites file by file. The <sha8> distinguishes two TIPS, not two
# prunes: archive-succeeds, remove-fails, operator-retries lands on the same
# name by design, and overwriting with identical content is the right outcome. A
# retry after a PARTIAL failure merges into the half-populated directory, which
# is also right — more is recovered and nothing is lost.
#
# stdout: `ARCHIVE=<path>` (or `ARCHIVE=-` when there was nothing to copy), then
# one `COPIED=<name>` line per item.
#
# Exit codes, because a destructive step is gated on them:
#   0  everything was copied, or there was nothing to copy
#   1  at least one copy failed — the failures are named on stderr
#   2  usage, or the environment (unreadable worktree, no main repo, no
#      writable destination)
set -uo pipefail

GANTRY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=session_paths.sh
. "$GANTRY/session_paths.sh"

die() { printf 'archive_artifacts: %s\n' "$1" >&2; exit 2; }

[ "$#" -eq 3 ] || die "usage: archive_artifacts.sh <worktree-path> <branch> <head-sha>"

ROOT="$1"
BRANCH="$2"
SHA="$3"

# The same test worktree_artifacts.sh makes, `-x` included, so the two agree on
# what "readable" means — see its header for why traversal is the part that
# matters.
[ -n "$ROOT" ] && [ -d "$ROOT" ] && [ -r "$ROOT" ] && [ -x "$ROOT" ] \
  || die "not a readable, traversable directory: $ROOT"

# What to copy is the one definition of it. A non-zero exit here is an
# environment problem, not an empty answer, so it is fatal rather than silently
# archiving nothing and letting the caller remove the worktree.
ARTIFACTS="$(bash "$GANTRY/worktree_artifacts.sh" "$ROOT")" \
  || die "could not read the artifacts of $ROOT"

if [ "$ARTIFACTS" = "-" ]; then
  # Nothing to archive is a SUCCESS. A worktree holding no artifacts must stay
  # prunable — making this non-zero would wedge every ordinary worktree.
  echo "ARCHIVE=-"
  exit 0
fi

MAIN_ROOT="$(git -C "$ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
  || die "not inside a git repository: $ROOT"
MAIN_ROOT="$(dirname "$MAIN_ROOT")"
[ -n "$MAIN_ROOT" ] || die "could not resolve the main repository root of $ROOT"

# `slugify -` is the empty string, and `-` is exactly what detect_candidates.sh
# emits for a detached worktree — so this fallback is load-bearing, not defensive.
SLUG="$(slugify "$BRANCH")"
[ -z "$SLUG" ] && SLUG="detached"

SHA8="$(printf '%s' "$SHA" | cut -c1-8)"
[ -z "$SHA8" ] && SHA8="nosha"

DEST="$(sessions_dir "$MAIN_ROOT")/worktrees/$(date +%F)-$SLUG-$SHA8"
mkdir -p "$DEST" || die "could not create the archive directory: $DEST"

echo "ARCHIVE=$DEST"

# One artifact per line, read in the current shell via process substitution —
# a pipe into `while` would run the loop in a subshell and $failed would come
# back empty, i.e. a partial archive reporting success.
failed=''
while IFS= read -r a; do
  [ -n "$a" ] || continue
  case "$a" in
    */)
      sub="${a%/}"
      if mkdir -p "$DEST/$sub" && cp -R "$ROOT/$sub/." "$DEST/$sub/" 2>/dev/null; then
        echo "COPIED=$a"
      else
        failed="$failed $a"
      fi
      ;;
    *)
      if cp "$ROOT/$a" "$DEST/$a" 2>/dev/null; then
        echo "COPIED=$a"
      else
        failed="$failed $a"
      fi
      ;;
  esac
done < <(printf '%s\n' "$ARTIFACTS" | tr ',' '\n')

if [ -n "$failed" ]; then
  printf 'archive_artifacts: could not copy to %s:%s\n' "$DEST" "$failed" >&2
  exit 1
fi
