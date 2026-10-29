#!/usr/bin/env bash
#
# lib/worktree_artifacts.sh answers "what is this worktree holding?" from the
# FILESYSTEM, because git cannot answer it: the chain's artifacts are excluded,
# `git status --porcelain` does not list ignored files, and `git worktree
# remove` therefore deletes them with rc 0 and no warning.
#
# Order is the arrays' order, never the filesystem's — two worktrees holding the
# same set must print the same string, or a caller diffing two reports sees a
# change that is not one.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

WA="$GANTRY_ROOT/lib/worktree_artifacts.sh"

run_wa() {  # run_wa <path> — sets WA_OUT and WA_RC
  WA_OUT="$(bash "$WA" "$@" 2>/dev/null)"
  WA_RC=$?
  return 0
}

empty="$CASE_TMP/holds-nothing"
mkdir -p "$empty"
run_wa "$empty"
assert_rc 0 "$WA_RC" "an empty root is answered, not an error"
assert_contains "$WA_OUT" "-" "an empty root prints -"

held="$CASE_TMP/holds-some"
mkdir -p "$held/.claude/artifacts"
printf '# handover\n' >"$held/handover.md"
printf 'gate ran\n' >"$held/.claude/artifacts/gate-1.log"
run_wa "$held"
assert_rc 0 "$WA_RC" "a root holding artifacts is answered"
if [ "$WA_OUT" = "handover.md,.claude/artifacts/" ]; then
  _pass "handover.md plus a non-empty .claude/artifacts/ is reported as both"
else
  _fail "expected 'handover.md,.claude/artifacts/', got '$WA_OUT'"
fi

# An empty .claude/artifacts/ is a directory a phase created and never wrote to.
# There is nothing to lose, so it is not reported as held — otherwise every
# worktree would read as artifact-bearing and the signal would mean nothing.
bare_dir="$CASE_TMP/empty-artifacts"
mkdir -p "$bare_dir/.claude/artifacts"
run_wa "$bare_dir"
assert_contains "$WA_OUT" "-" "an EMPTY .claude/artifacts/ is not reported as held"

# Order is the array's, not creation order: review.md written first must still
# come last.
ordered="$CASE_TMP/order"
mkdir -p "$ordered"
printf 'r\n' >"$ordered/review.md"
printf 'h\n' >"$ordered/handover.md"
printf 'p\n' >"$ordered/plan.md"
printf 't\n' >"$ordered/task.md"
run_wa "$ordered"
if [ "$WA_OUT" = "task.md,plan.md,handover.md,review.md" ]; then
  _pass "the order is the array's, regardless of creation order"
else
  _fail "expected 'task.md,plan.md,handover.md,review.md', got '$WA_OUT'"
fi

printf 'j\n' >"$ordered/journal.jsonl"
run_wa "$ordered"
assert_contains "$WA_OUT" "task.md,plan.md,handover.md,review.md,journal.jsonl" \
  "run state follows the contract's four"

run_wa "$CASE_TMP/does-not-exist"
assert_rc 2 "$WA_RC" "a missing path is exit 2"
if [ -z "$WA_OUT" ]; then
  _pass "and prints nothing on stdout — a caller must not read it as 'holds nothing'"
else
  _fail "a missing path printed '$WA_OUT' on stdout"
fi

# Called directly rather than through the helper: the helper forwards "$@", and
# a no-argument call through it is the one shape shellcheck reads as a mistake.
bash "$WA" >/dev/null 2>&1
assert_rc 2 "$?" "no argument is a usage error"

# A file where a directory was expected is not a worktree either.
printf 'x\n' >"$CASE_TMP/not-a-dir"
run_wa "$CASE_TMP/not-a-dir"
assert_rc 2 "$WA_RC" "a plain file is exit 2, not an empty answer"

# A directory that is readable but NOT traversable is the sharpest form of the
# `-`/`?` flattening this script exists to prevent. The `-f` tests need
# traversal, not read permission — so without `-x` in the guard a mode-400
# worktree holding a handover answers `-` with rc 0, prune reads "holds
# nothing", archive_artifacts.sh reports ARCHIVE=- as a success, and the
# worktree is removed with the handover still in it.
nox="$CASE_TMP/no-traverse"
mkdir -p "$nox"
printf '# handover\n' >"$nox/handover.md"
chmod 400 "$nox"
run_wa "$nox"
if [ "$WA_RC" -eq 2 ]; then
  _pass "a readable but non-traversable directory is exit 2, not 'holds nothing'"
  if [ -z "$WA_OUT" ]; then
    _pass "and prints nothing, so the caller reports ? rather than -"
  else
    _fail "a non-traversable directory printed '$WA_OUT'"
  fi
else
  # Running as root defeats the mode bits; say so rather than passing vacuously.
  _fail "expected rc 2 from a non-traversable directory, got $WA_RC (running as root?)"
fi
chmod 700 "$nox"

finish
