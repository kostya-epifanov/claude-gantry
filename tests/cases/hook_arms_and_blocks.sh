#!/usr/bin/env bash
#
# The guarantee itself: with the hook armed, a red gate BLOCKS the stop and a
# green one lets it through.
#
# Exit 2 is the only code that blocks a Stop hook — 0 is success and any other
# non-zero is a non-blocking hook error that fails open. So "the model cannot
# decline the gate" reduces entirely to: does this script exit 2 on red?

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

# --- red: the stop must be refused -------------------------------------------
red="$(mkrepo armed_red)"
write_task "$red" implementing
write_gates "$red" 1

run_hook "$red"
assert_rc 2 "$HOOK_RC" "a red gate blocks the stop"
assert_contains "$HOOK_OUT" "RED" "the verdict names RED"
assert_gate_ran "$red" "the gate actually ran"
assert_file_contains "$(hooklog "$red")" "decision=fire.*verdict=RED" \
  "the audit log records the block"

# --- green: the stop must proceed --------------------------------------------
green="$(mkrepo armed_green)"
write_task "$green" implementing
write_gates "$green" 0

run_hook "$green"
assert_rc 0 "$HOOK_RC" "a green gate lets the stop pass"
assert_contains "$HOOK_OUT" "PASS" "the verdict names PASS"
assert_gate_ran "$green" "the gate actually ran"
assert_file_contains "$(hooklog "$green")" "decision=fire.*verdict=PASS" \
  "the audit log records the pass"

# The green path reports through a systemMessage built with `jq --arg`, and
# degrades to a plain stderr line when jq is absent. Only assert the JSON shape
# where jq exists, so a jq-less runner does not fail for the wrong reason.
if command -v jq >/dev/null 2>&1; then
  assert_contains "$HOOK_OUT" "systemMessage" "the green path emits its systemMessage JSON"
fi

# --- a gate that cannot run is red, not "unrunnable" --------------------------
# The inline call in gantry:implement exempts exit 2 as a broken environment.
# The hook deliberately carries no such exemption: from where it stands, a gate
# that could not run has not proved the tree good, and an unproved tree does
# not get to stop.
broken="$(mkrepo armed_broken_env)"
write_task "$broken" implementing
write_gates "$broken" 2

run_hook "$broken"
assert_rc 2 "$HOOK_RC" "a gate exiting 2 is treated as red by the hook"

finish
