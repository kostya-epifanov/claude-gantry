#!/usr/bin/env bash
#
# skills/prune-worktrees/scripts/detect_candidates.sh is the only classifier of
# worktrees, and nothing exercised it until this case. It now emits a seventh
# field saying which chain artifacts each worktree holds, and three properties
# of that field are load-bearing:
#
#   1. It changes NO classification. A clean worktree holding only excluded
#      artifacts stays `candidate`/`keep` — never `dirty`. Every gantry worktree
#      holds artifacts, so classifying on them would make the prune skill inert
#      (task.md's "Out of scope" says so).
#   2. It cannot truncate the row stream. The script runs under
#      `set -euo pipefail`, where a command substitution exiting non-zero ends
#      the whole script — so a worktree git still lists but whose directory is
#      gone would have cut every later row, and a caller would bucket a partial
#      candidate list without knowing. Hence `|| echo '?'`.
#   3. `?` (could not be read) is not `-` (holds nothing). Flattening the two is
#      how a truncation becomes invisible.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

DETECT="$GANTRY_ROOT/skills/prune-worktrees/scripts/detect_candidates.sh"

repo="$(mkrepo prune-repo)"

# The exclusion is what makes this interesting: an ignored file leaves
# `git status --porcelain` empty, so git itself reports the worktree as clean
# and would remove it silently. gantry's real runs use .git/info/exclude; a
# committed .gitignore is the shape a worktree inherits in a fixture.
{
  printf '/task.md\n/plan.md\n/handover.md\n/review.md\n'
  printf 'journal.jsonl\n.claude/artifacts/\n'
} >"$repo/.gitignore"
commit_all "$repo" "exclude the chain artifacts"

held="$(mkworktree "$repo" holds-handover feat/holds-handover)"
printf '# handover\n\n- a deferred finding\n' >"$held/handover.md"

dirty="$(mkworktree "$repo" really-dirty feat/really-dirty)"
printf 'not ignored by anything\n' >"$dirty/stray.txt"

clean="$(mkworktree "$repo" holds-nothing feat/holds-nothing)"

gone="$(mkworktree "$repo" vanished feat/vanished)"
# Deleted WITHOUT `git worktree prune`, which is a real state git keeps listing.
rm -rf "$gone"

OUT="$(cd "$repo" && bash "$DETECT" 2>&1)"
RC=$?
assert_rc 0 "$RC" "the detector completes with a worktree missing from disk"

row_for() {  # row_for <path>
  printf '%s\n' "$OUT" | awk -F'|' -v p="$1" '$1 == p { print; exit }'
}
field() {  # field <row> <n>
  printf '%s\n' "$1" | cut -d'|' -f"$2"
}
assert_eq() {  # assert_eq <got> <want> <label>
  if [ "$1" = "$2" ]; then _pass "$3"; else _fail "$3 — got '$1', want '$2'"; fi
}

# --- every row is still there ------------------------------------------------

for p in "$repo" "$held" "$dirty" "$clean" "$gone"; do
  if [ -n "$(row_for "$p")" ]; then
    _pass "a row was emitted for $(basename "$p")"
  else
    _fail "no row for $p — the stream was truncated"
  fi
done

# --- the artifact field ------------------------------------------------------

held_row="$(row_for "$held")"
assert_contains "$(field "$held_row" 7)" "handover.md" \
  "a worktree holding an excluded handover.md reports it in field 7"
case "$(field "$held_row" 3)" in
  candidate|keep) _pass "and is still classified candidate/keep, never dirty" ;;
  *)              _fail "artifact-bearing worktree classified '$(field "$held_row" 3)'" ;;
esac

dirty_row="$(row_for "$dirty")"
assert_eq "$(field "$dirty_row" 3)" dirty "a non-ignored untracked file still reports dirty"

clean_row="$(row_for "$clean")"
assert_eq "$(field "$clean_row" 7)" '-' "a worktree holding nothing reports -"

gone_row="$(row_for "$gone")"
assert_eq "$(field "$gone_row" 7)" '?' "a worktree whose directory is gone reports ? and not -"

# --- the row shape -----------------------------------------------------------

badrows=0
while IFS= read -r line; do
  case "$line" in FETCH:*|'') continue ;; esac
  n="$(printf '%s\n' "$line" | awk -F'|' '{print NF}')"
  if [ "$n" -ne 7 ]; then
    printf '    row has %s fields, want 7: %s\n' "$n" "$line"
    badrows=1
  fi
done <<EOF
$OUT
EOF
if [ "$badrows" -eq 0 ]; then
  _pass "every emitted row has exactly 7 pipe-delimited fields"
else
  _fail "a row does not have 7 fields"
fi

# The `bare` row is emitted from its own `echo` and is unreachable from a
# fixture — `git worktree list --porcelain` only prints `bare` for a bare main
# repository, which this script's $MAIN_ROOT resolution does not support. So
# its field count is asserted against the source: every row-emitting `echo` in
# the script must carry 7 fields, or `bare` silently keeps the old 6.
if awk '
  /echo "\$path/ {
    n = gsub(/\|/, "|") + 1
    if (n != 7) { printf "    %s: %s fields\n", FILENAME, n; bad = 1 }
    seen++
  }
  END { exit (seen >= 2 && !bad) ? 0 : 1 }
' "$DETECT"; then
  _pass "every row-emitting echo in the script carries 7 fields, the bare row included"
else
  _fail "a row-emitting echo in detect_candidates.sh does not carry 7 fields"
fi

finish
