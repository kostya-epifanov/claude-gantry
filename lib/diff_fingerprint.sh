#!/usr/bin/env bash
# diff_fingerprint.sh — one token for the working tree's diff against a base.
# Run with: bash diff_fingerprint.sh <base>   (from anywhere inside the repo/worktree)
#
# WHY THIS EXISTS. gantry:review writes review.md — the findings that are in
# scope to fix — and the fix step applies them later, possibly in another
# session, possibly after the tree moved. A findings file for a different diff
# applied to this one is worse than no findings file, so review.md records the
# token this prints and the fix step refuses when it no longer matches.
#
# It is a script rather than a pipeline in a skill's argv because a
# worktree-isolated session refuses a command with a pipe or a substitution in
# it (see lib/journal_append.sh for the history).
#
# WHAT IT HASHES: `git diff <base>` — committed plus working-tree changes, the
# same view gantry:review reads — then the short status with every untracked
# path, then the content hash of each untracked file. The last part is what
# makes an edit to a new file change the token: its status line would not.
# The chain's own artifacts (task.md, plan.md, handover.md, review.md, the gate
# logs, journal.jsonl) are excluded from all three BY PATHSPEC, not only by
# trusting .git/info/exclude: in a repo where they are still tracked (the case
# lib/detect_stage.sh's task_is_inherited() exists for) the status write a
# review makes to task.md would otherwise move the token review.md just
# recorded, and the fix step would refuse the findings it had just written.
#
# stdout: one token. Exit 0 = printed · 2 = usage, not a repo, or <base> does
# not resolve.
set -uo pipefail

die() { printf 'diff_fingerprint: %s\n' "$1" >&2; exit 2; }

[ "$#" -eq 1 ] || die "usage: diff_fingerprint.sh <base>"
BASE="$1"
[ -n "$BASE" ] || die "usage: diff_fingerprint.sh <base>"

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"
git rev-parse --quiet --verify "$BASE^{commit}" >/dev/null 2>&1 || die "base does not resolve to a commit: $BASE"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "could not resolve the repository root"
cd "$ROOT" || die "could not enter $ROOT"

# `:!<path>` is git's exclude pathspec; with no positive pathspec beside it,
# "everything except". A bare name matches only that path at the root.
EXCLUDE=(':!task.md' ':!plan.md' ':!handover.md' ':!review.md' ':!.claude/artifacts' ':!journal.jsonl')

untracked_hashes() {
  git ls-files --others --exclude-standard -z -- "${EXCLUDE[@]}" 2>/dev/null \
    | while IFS= read -r -d '' f; do
        [ -f "$f" ] || continue
        printf '%s ' "$f"
        git hash-object -- "$f" 2>/dev/null || printf 'unreadable\n'
      done
}

TOKEN="$(
  {
    git diff "$BASE" -- "${EXCLUDE[@]}" 2>/dev/null
    printf '\n--status--\n'
    git status --short --untracked-files=all -- "${EXCLUDE[@]}" 2>/dev/null
    printf '\n--untracked--\n'
    untracked_hashes
  } | git hash-object --stdin 2>/dev/null
)"
[ -n "$TOKEN" ] || die "could not compute the token"
printf '%s\n' "$TOKEN"
