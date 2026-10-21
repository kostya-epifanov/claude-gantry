#!/usr/bin/env bash
#
# lib/diff_fingerprint.sh prints one token for the tree's diff against a base.
# review.md records it, and `gantry:review --fix` in apply mode refuses when it
# no longer matches — so the token has to move when the diff moves, including
# when the only change is INSIDE an untracked file, and it has to stay put when
# nothing but the chain's own excluded artifacts changed.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

FP="$GANTRY_ROOT/lib/diff_fingerprint.sh"

# fp <repo> <base> — sets FP_TOKEN and FP_RC. Called directly, never inside a
# command substitution: a subshell would keep both variables to itself.
fp() {
  FP_TOKEN="$(cd "$1" && bash "$FP" "$2" 2>/dev/null)"
  FP_RC=$?
  return 0
}

repo="$(mkrepo fp)"
git -C "$repo" branch -m master >/dev/null 2>&1
git -C "$repo" checkout -q -b feat/x >/dev/null 2>&1

fp "$repo" master; clean1="$FP_TOKEN"
assert_rc 0 "$FP_RC" "a clean tree against its base yields a token"
fp "$repo" master; clean2="$FP_TOKEN"
[ "$clean1" = "$clean2" ] && _pass "the same tree twice gives the same token" \
  || _fail "the same tree gave two tokens: $clean1 / $clean2"
case "$clean1" in
  *[[:space:]]*) _fail "the token contains whitespace: $clean1" ;;
  '') _fail "the token is empty" ;;
  *) _pass "the token is one whitespace-free word" ;;
esac

printf 'changed\n' > "$repo/README"
fp "$repo" master; mod="$FP_TOKEN"
[ "$mod" != "$clean1" ] && _pass "a working-tree edit moves the token" \
  || _fail "a working-tree edit left the token unchanged"

commit_all "$repo" "commit the edit"
fp "$repo" master; committed="$FP_TOKEN"
assert_rc 0 "$FP_RC" "a committed change still yields a token"
[ "$committed" != "$clean1" ] && _pass "a committed change counts: the diff is against the base, not the index" \
  || _fail "a committed change left the token at the clean value"

printf 'new\n' > "$repo/new.txt"
fp "$repo" master; untracked1="$FP_TOKEN"
[ "$untracked1" != "$committed" ] && _pass "an untracked file moves the token" \
  || _fail "an untracked file left the token unchanged"

printf 'new, edited\n' > "$repo/new.txt"
fp "$repo" master; untracked2="$FP_TOKEN"
[ "$untracked2" != "$untracked1" ] && _pass "an edit INSIDE an untracked file moves the token (its status line would not)" \
  || _fail "editing an untracked file left the token unchanged"

# The chain's own artifacts are excluded and must not move the token: a review
# that writes review.md and sets task.md's status must not invalidate itself.
excl="$(git -C "$repo" rev-parse --path-format=absolute --git-path info/exclude)"
printf '/task.md\n/plan.md\n/handover.md\n/review.md\n.claude/artifacts/\n' >> "$excl"
fp "$repo" master; before="$FP_TOKEN"
printf -- '---\nstatus: reviewed\n---\n' > "$repo/task.md"
printf '# Review\n' > "$repo/review.md"
mkdir -p "$repo/.claude/artifacts/headless"
printf '{}' > "$repo/.claude/artifacts/headless/review.json"
fp "$repo" master; after="$FP_TOKEN"
[ "$before" = "$after" ] && _pass "excluded artifacts (task.md, review.md, the result files) do not move the token" \
  || _fail "writing excluded artifacts moved the token"

# Two different trees give different tokens.
other="$(mkrepo fp-other)"
git -C "$other" branch -m master >/dev/null 2>&1
printf 'something else\n' > "$other/README"
fp "$other" master; other_tok="$FP_TOKEN"
[ "$other_tok" != "$after" ] && _pass "two different working trees give different tokens" \
  || _fail "two different trees collided on one token"

# --- errors ------------------------------------------------------------------------------

fp "$repo" no-such-base
assert_rc 2 "$FP_RC" "a base that does not resolve is exit 2"
FP_OUT="$(cd "$repo" && bash "$FP" 2>&1)"; FP_RC=$?
assert_rc 2 "$FP_RC" "no base at all is a usage error"
FP_OUT="$(cd "$repo" && bash "$FP" master extra 2>&1)"; FP_RC=$?
assert_rc 2 "$FP_RC" "two arguments is a usage error"
plain="$(mkdir_plain fp-plain)"
FP_OUT="$(cd "$plain" && bash "$FP" master 2>&1)"; FP_RC=$?
assert_rc 2 "$FP_RC" "outside a repository is exit 2"

finish
