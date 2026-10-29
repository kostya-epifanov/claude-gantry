#!/usr/bin/env bash
# worktree_artifacts.sh — which chain artifacts a worktree is holding.
# Run with: bash worktree_artifacts.sh <worktree-path>
#
# WHY THIS EXISTS. The chain's artifacts are kept out of git on purpose
# (docs/ARCHITECTURE.md § "The artifact contract"), and `git status --porcelain`
# does not list ignored files — so a worktree holding every one of them reports
# CLEAN, and `git worktree remove` then deletes the directory with rc 0 and no
# warning. Verified on git 2.55: an ignored file is removed silently, while a
# non-ignored untracked file aborts the removal. The exclusion that keeps the
# artifacts out of the diff is precisely what makes git willing to destroy them.
#
# So the question "is this worktree holding anything a human has not seen?"
# cannot be asked of git. It is asked of the FILESYSTEM, here, and nowhere else
# in this repository asks it any other way.
#
# stdout: the artifacts present at that root, comma-separated in the fixed
# order of the arrays below, or `-` when there are none. Order is the arrays',
# never the filesystem's, so two worktrees holding the same set print the same
# string.
#
# Exit codes: 0 = answered (including `-`) · 2 = the path is not a readable,
# TRAVERSABLE directory, nothing printed on stdout.
#
# `-x` is part of that test and not decoration: the `-f` tests below need
# traversal, not read permission, so a directory that is `-r` but not `-x`
# answers `-` for every artifact it holds. That is the `-`/`?` flattening this
# script exists to prevent — prune would read "holds nothing", archive would
# report `ARCHIVE=-` as a success, and the worktree would be removed with the
# handover still in it.
set -uo pipefail

# The artifact contract's five names, and nothing else. scripts/verify.sh
# compares THIS array against the `ensure_excluded.sh` calls under skills/, so
# adding a sixth artifact to the contract means adding it here — and a name
# added here that no call excludes is a red check. Keep the two arrays split:
# fold the run state in and that check would need a third list of exclusions to
# subtract again.
ROOT_ARTIFACTS=(task.md plan.md handover.md review.md qa.md)

# Run state. Not part of the contract, equally unrecoverable once the directory
# is gone: the journal is an unattended run's only trail and the gate logs are
# its only evidence.
RUN_ARTIFACTS=(journal.jsonl .claude/artifacts/)

[ "$#" -eq 1 ] || { printf 'usage: worktree_artifacts.sh <worktree-path>\n' >&2; exit 2; }

ROOT="$1"
[ -n "$ROOT" ] && [ -d "$ROOT" ] && [ -r "$ROOT" ] && [ -x "$ROOT" ] \
  || { printf 'worktree_artifacts: not a readable, traversable directory: %s\n' "$ROOT" >&2; exit 2; }

found=''
for a in "${ROOT_ARTIFACTS[@]}" "${RUN_ARTIFACTS[@]}"; do
  case "$a" in
    */) [ -d "$ROOT/${a%/}" ] || continue
        # An empty .claude/artifacts/ is a directory a phase created and never
        # wrote to. Nothing to lose, so it is not reported as held.
        [ -n "$(ls -A "$ROOT/${a%/}" 2>/dev/null)" ] || continue ;;
    *)  [ -f "$ROOT/$a" ] || continue ;;
  esac
  found="$found,$a"
done

if [ -n "$found" ]; then
  printf '%s\n' "${found#,}"
else
  printf '%s\n' '-'
fi
