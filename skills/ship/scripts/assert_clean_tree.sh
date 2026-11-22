#!/usr/bin/env bash
# assert_clean_tree.sh — after ship commits, is anything still outstanding?
#
# ship stages what is on disk when it runs; a file edited later, or one left out
# of a partial staging, is not in the commit and would be silently left behind by
# the push that follows. This is the check that says so, before the push.
#
# Read-only: one `git status`. Modifies nothing, and never commits or excludes.
# Run from inside the repo/worktree:  bash assert_clean_tree.sh
#
# stdout:
#   CLEAN                      nothing outstanding            (exit 0)
#   DIRTY:<n>                  n outstanding entries, then one line each:
#   PATH:<XY> <path>           git's two-letter status, then the path, unquoted;
#                              a rename/copy reads `<new> (from <old>)`  (exit 1)
# Not a repo, or `git status` itself failed                   (exit 2, no CLEAN)
#
# Files excluded via .git/info/exclude (task.md, plan.md, journal.jsonl,
# .claude/artifacts/ ...) do not appear in porcelain and are never reported.
set -uo pipefail

[ $# -eq 0 ] || { echo "assert_clean_tree: takes no arguments" >&2; exit 2; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
  || { echo "assert_clean_tree: not inside a git work tree" >&2; exit 2; }

# Capture to a file so git's own exit status is checked: empty output from a
# FAILED status must never be read as a clean tree.
tmp="$(mktemp "${TMPDIR:-/tmp}/assert-clean.XXXXXX")" || exit 2
trap 'rm -f "$tmp"' EXIT
git status --porcelain -z --untracked-files=all >"$tmp" 2>/dev/null \
  || { echo "assert_clean_tree: git status failed" >&2; exit 2; }

if [ ! -s "$tmp" ]; then
  echo "CLEAN"
  exit 0
fi

entries=()
while IFS= read -r -d '' rec; do
  xy="${rec:0:2}"
  path="${rec:3}"
  case "$xy" in
    R*|C*|*R|*C)
      IFS= read -r -d '' orig || orig=""
      entries+=("PATH:$xy $path (from $orig)") ;;
    *) entries+=("PATH:$xy $path") ;;
  esac
done <"$tmp"

echo "DIRTY:${#entries[@]}"
printf '%s\n' "${entries[@]}"
exit 1
