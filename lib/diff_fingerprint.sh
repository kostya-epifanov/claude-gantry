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
# WHAT IT HASHES: the content hash of every path that differs from the merge-base
# with <base> — committed plus working-tree changes, the same view gantry:review
# reads — and of every untracked path, with its mode (symlink target, gitlink commit). Content, not `git status` or diff text,
# so committing the reviewed tree leaves the token alone (see paths_and_hashes).
# The chain's own artifacts (task.md, plan.md, handover.md, review.md, the gate
# logs, journal.jsonl) are excluded from both inputs BY PATHSPEC, not only by
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

# One "<path> <mode+content hash | link/gitlink id | deleted>" line per path the change touches: every
# path that differs from the merge-base with <base> (committed or in the working
# tree) plus every untracked path. The token reads CONTENT, never `git status`
# or the diff text, so it is the same whether the change is committed or not —
# gantry:ship commits after gantry:review has recorded the token, and a token
# that moved on commit would make every review read stale. Keying on the
# merge-base rather than <base>'s tip keeps a fetch that moves origin/<base>
# from moving it too.
paths_and_hashes() {
  local from
  from="$(git merge-base "$BASE" HEAD 2>/dev/null)" || from=""
  [ -n "$from" ] || from="$BASE"
  {
    git diff --no-renames --name-only -z "$from" -- "${EXCLUDE[@]}" 2>/dev/null
    git ls-files --others --exclude-standard -z -- "${EXCLUDE[@]}" 2>/dev/null
  } | sort -zu \
    | while IFS= read -r -d '' f; do
        printf '%s ' "$f"
        # mode and object id belong to the token: a chmod, a symlink retarget or a
        # gitlink bump changes the change without changing any file's content.
        if [ -L "$f" ]; then
          printf 'link %s\n' "$(readlink -- "$f" | git hash-object --stdin 2>/dev/null)"
        elif [ -d "$f" ]; then
          printf 'gitlink %s\n' "$(git -C "$f" rev-parse HEAD 2>/dev/null || printf 'unknown')"
        elif [ -f "$f" ]; then
          if [ -x "$f" ]; then printf '755 '; else printf '644 '; fi
          git hash-object -- "$f" 2>/dev/null || printf 'unreadable\n'
        else
          printf 'deleted\n'
        fi
      done
}

TOKEN="$(paths_and_hashes | git hash-object --stdin 2>/dev/null)"
[ -n "$TOKEN" ] || die "could not compute the token"
printf '%s\n' "$TOKEN"
