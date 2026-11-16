#!/usr/bin/env bash
#
# detect_candidates.sh counts a worktree whose head is an ancestor of an
# origin/integration/* branch as merged, and names that branch in merged_into.
# The fixture has no `origin` remote on purpose: the detector's
# `git fetch origin --prune` then fails and leaves the hand-made
# refs/remotes/origin/integration/* refs alone (a real origin would prune them).

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

DETECT="$GANTRY_ROOT/skills/prune-worktrees/scripts/detect_candidates.sh"

repo="$(mkrepo prune-integ)"

# commit_in <worktree> <file> — one commit of the worktree's own.
commit_in() {
  printf '%s\n' "$2" >"$1/$2"
  git -C "$1" add "$2"
  git -C "$1" -c user.email=t@t -c user.name=t commit -q -m "add $2"
}

merged="$(mkworktree "$repo" merged-integ feat/merged-integ)"
commit_in "$merged" merged.txt

unmerged="$(mkworktree "$repo" unmerged feat/unmerged)"
commit_in "$unmerged" unmerged.txt

lane="$(mkworktree "$repo" lane integration/2026-11-16)"
commit_in "$lane" lane.txt

# Merged into master as well as into an integration branch: master wins, the
# integration branches must not pile onto the field.
both="$(mkworktree "$repo" both feat/both)"
commit_in "$both" both.txt

# Integration x holds merged-integ's commit; the lane's own branch is pushed.
git -C "$repo" update-ref refs/remotes/origin/integration/x "$(git -C "$merged" rev-parse HEAD)"
git -C "$repo" update-ref refs/remotes/origin/integration/2026-11-16 "$(git -C "$lane" rev-parse HEAD)"
git -C "$repo" update-ref refs/remotes/origin/integration/y "$(git -C "$both" rev-parse HEAD)"
git -C "$repo" -c user.email=t@t -c user.name=t merge -q --no-ff -m "merge both" feat/both

OUT="$(cd "$repo" && bash "$DETECT" 2>&1)"
RC=$?
assert_rc 0 "$RC" "the detector completes"

row_for() { printf '%s\n' "$OUT" | awk -F'|' -v p="$1" '$1 == p { print; exit }'; }
field() { printf '%s\n' "$1" | cut -d'|' -f"$2"; }
assert_eq() { if [ "$1" = "$2" ]; then _pass "$3"; else _fail "$3 — got '$1', want '$2'"; fi; }

row="$(row_for "$merged")"
assert_eq "$(field "$row" 3)" candidate "a head merged only into origin/integration/x is a candidate"
assert_eq "$(field "$row" 5)" integration/x "merged_into names the integration branch"

row="$(row_for "$unmerged")"
assert_eq "$(field "$row" 3)" keep "an unmerged recent head stays keep"
assert_eq "$(field "$row" 5)" '-' "and merged_into is -"

row="$(row_for "$lane")"
assert_eq "$(field "$row" 5)" '-' "a lane's own pushed integration branch is not merged into itself"

row="$(row_for "$both")"
assert_eq "$(field "$row" 5)" "$(git -C "$repo" symbolic-ref --short HEAD)" "a head merged into master names the base branch only, not integration branches"

bad=0
while IFS= read -r line; do
  case "$line" in FETCH:*|'') continue ;; esac
  [ "$(printf '%s\n' "$line" | awk -F'|' '{print NF}')" -eq 7 ] || bad=1
done <<EOT
$OUT
EOT
if [ "$bad" -eq 0 ]; then _pass "every row still has 7 fields"; else _fail "a row does not have 7 fields"; fi

finish
