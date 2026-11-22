#!/usr/bin/env bash
#
# lib/review_fresh.sh answers "does review.md still describe this tree?" for
# both gantry:ship (publish the Risk level, or `unassessed`) and
# gantry:review --fix (apply, or refuse). Pinned here: fresh, edited-after,
# committed-after (ship commits), another branch, the applied: diff= token, the
# --findings mode, and the absent / malformed exits.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

RF="$GANTRY_ROOT/lib/review_fresh.sh"
FP="$GANTRY_ROOT/lib/diff_fingerprint.sh"

# rf <repo> [args...] — sets RF_OUT and RF_RC (never in a command substitution).
rf() {
  local repo="$1"; shift
  RF_OUT="$(cd "$repo" && bash "$RF" "$@" 2>/dev/null)"
  RF_RC=$?
  return 0
}
token() { (cd "$1" && bash "$FP" master); }
write_review() { # <repo> <branch> <token> [extra line]
  { printf '# Review\nbranch: %s\nbase: master\ndiff: %s\nsource: self-review\n\n## Address now\nNone.\n' "$2" "$3"
    [ -z "${4:-}" ] || printf '%s\n' "$4"; } > "$1/review.md"
}

repo="$(mkrepo rf)"
git -C "$repo" branch -m master >/dev/null 2>&1
git -C "$repo" checkout -q -b feat/x >/dev/null 2>&1
printf 'work\n' > "$repo/a.txt"
printf '/review.md\n' >> "$(git -C "$repo" rev-parse --path-format=absolute --git-path info/exclude)"

rf "$repo"
assert_rc 3 "$RF_RC" "no review.md is exit 3"
case "$RF_OUT" in FRESH:absent*) _pass "…reported as FRESH:absent" ;; *) _fail "expected FRESH:absent, got: $RF_OUT" ;; esac

t0="$(token "$repo")"
write_review "$repo" feat/x "$t0"
rf "$repo"
assert_rc 0 "$RF_RC" "a review of this very tree is fresh"
case "$RF_OUT" in FRESH:yes*) _pass "…reported as FRESH:yes" ;; *) _fail "expected FRESH:yes, got: $RF_OUT" ;; esac

commit_all "$repo" "ship commits the reviewed content"
rf "$repo"
assert_rc 0 "$RF_RC" "committing the reviewed content keeps the review fresh"

printf 'later\n' > "$repo/b.txt"
commit_all "$repo" "a commit lands after the review"
rf "$repo"
assert_rc 1 "$RF_RC" "a commit after the review makes it stale"
case "$RF_OUT" in FRESH:stale*) _pass "…reported as FRESH:stale" ;; *) _fail "expected FRESH:stale, got: $RF_OUT" ;; esac

# applied: diff= is the tree as the fix step left it
t1="$(token "$repo")"
write_review "$repo" feat/x "$t0" "applied: 2026-11-16T00:00:00Z gate=0 diff=$t1"
rf "$repo"
assert_rc 0 "$RF_RC" "an applied: diff= that matches the tree is fresh"
rf "$repo" --findings
assert_rc 1 "$RF_RC" "--findings ignores applied: and compares diff: only (a second --fix is refused)"
# the combined BASE-346 + BASE-420 line: mode= and seconds= sit between gate= and diff=
write_review "$repo" feat/x "$t0" "applied: 2026-11-16T00:00:00Z gate=0 mode=fast seconds=37 diff=$t1"
rf "$repo"
assert_rc 0 "$RF_RC" "diff= is still read when mode= and seconds= come before it"
write_review "$repo" feat/x "$t0" "applied: 2026-11-16T00:00:00Z gate=0 diff=$t0"
rf "$repo"
assert_rc 1 "$RF_RC" "an applied: diff= that does not match is stale"
write_review "$repo" feat/x "$t0" "applied: 2026-11-16T00:00:00Z gate=0"
rf "$repo"
assert_rc 1 "$RF_RC" "an applied: line without diff= (older format) falls back to diff:"

write_review "$repo" feat/other "$t1"
rf "$repo"
assert_rc 1 "$RF_RC" "a review of another branch is stale even with a matching token"

printf '# Review\nbranch: feat/x\n' > "$repo/review.md"
rf "$repo"
assert_rc 2 "$RF_RC" "a review without base:/diff: is exit 2"
write_review "$repo" feat/x "$t1"
sed -i 's/^base: master/base: no-such-base/' "$repo/review.md"
rf "$repo"
assert_rc 2 "$RF_RC" "a base that does not resolve is exit 2"

plain="$(mkdir_plain rf-plain)"
(cd "$plain" && bash "$RF") >/dev/null 2>&1; RF_RC=$?
assert_rc 2 "$RF_RC" "outside a repository is exit 2"
