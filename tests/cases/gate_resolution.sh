#!/usr/bin/env bash
#
# run_gates.sh resolves what to run in three tiers, and the first one is
# absolute: if .claude/gates.sh exists, it IS the gate and its exit code is the
# result. Auto-detection is a convenience for repos that have not bothered yet,
# never an override of a repo that has.
#
# The normalisation rule is the subtle half. Exit 2 and 3 are reserved for
# run_gates.sh's own conditions — "could not run" and "nothing was checked" —
# and callers act on them differently from an ordinary red. But a real check
# can exit 2 or 3 on its own (pytest exits 2 on a collection error, eslint on a
# fatal config error), and passing that through verbatim would make a genuinely
# red tree read as a broken environment: the one misclassification that stops
# the fix loop from ever fixing anything.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

# A stub npm keeps this independent of any real toolchain. Without it, a
# machine with no node would skip the JS gate and the case would pass for the
# wrong reason — the exact false green this suite exists to catch.
stub_cmd npm 1

# --- the repo's own gate wins over a detectable ecosystem --------------------
repo="$(mkrepo repo_gate_wins)"
printf '{\n  "name": "x",\n  "scripts": { "test": "exit 1" }\n}\n' >"$repo/package.json"
write_gates "$repo" 0

run_gate "$repo"
assert_rc 0 "$GATE_RC" "the repo-owned gate's exit code is the result"
assert_contains "$GATE_OUT" "repo-owned" "the transcript names the repo-owned gate"
assert_not_contains "$GATE_OUT" "js:test" "auto-detection did not also run"

# --- a repo gate exiting 2 or 3 is normalised to 1 ---------------------------
# Otherwise a red tree would be mistaken for one of run_gates.sh's own reserved
# conditions.
two="$(mkrepo repo_gate_two)"
write_gates "$two" 2
run_gate "$two"
assert_rc 1 "$GATE_RC" "a repo gate exiting 2 is reported as red"

three="$(mkrepo repo_gate_three)"
write_gates "$three" 3
run_gate "$three"
assert_rc 1 "$GATE_RC" "a repo gate exiting 3 is reported as red"

# --- an ordinary red passes through unchanged --------------------------------
one="$(mkrepo repo_gate_one)"
write_gates "$one" 1
run_gate "$one"
assert_rc 1 "$GATE_RC" "an ordinary red passes through as 1"

# --- with no repo gate, detection runs and a failing check is red ------------
detect="$(mkrepo detected)"
printf '{\n  "name": "x",\n  "scripts": { "test": "exit 1" }\n}\n' >"$detect/package.json"

run_gate "$detect"
assert_rc 1 "$GATE_RC" "a failing detected check makes the gate red"
assert_contains "$GATE_OUT" "js:test" "the transcript names the detected check"

finish
