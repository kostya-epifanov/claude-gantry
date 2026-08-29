#!/usr/bin/env bash
#
# NO-GATES is treated differently by mode on purpose, and the asymmetry is the
# point. Supervised, a repo with no detectable checks exits 0 and says so — a
# human is standing there and can decide. Unattended (--strict) the same repo
# exits 3 and the run refuses to push: with nobody watching, shipping code that
# ran zero checks is precisely the outcome the gate exists to prevent.
#
# This is also the documented soft spot — auto-detection can false-green on a
# repo whose real checks the heuristics cannot see — so the lenient path must
# at least be loud about it.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

repo="$(mkrepo nothing_to_run)"

run_gate "$repo"
assert_rc 0 "$GATE_RC" "no detectable checks passes when supervised"
assert_contains "$GATE_OUT" "NO-GATES" "and says NO-GATES rather than reporting green"
assert_contains "$GATE_OUT" ".claude/gates.sh" "and names the fix"

run_gate "$repo" --strict
assert_rc 3 "$GATE_RC" "the same repo is a hard refusal under --strict"
assert_contains "$GATE_OUT" "NO-GATES" "the strict refusal still explains itself"

finish
