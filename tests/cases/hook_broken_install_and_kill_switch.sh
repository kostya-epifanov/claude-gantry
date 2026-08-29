#!/usr/bin/env bash
#
# Two ways the hook stops being the thing it claims to be, and the opposite
# directions they must fail in.
#
# A BROKEN INSTALL FAILS RED. If run_gates.sh is missing or unreadable, the
# hook cannot prove the tree is good — and an unproved tree does not get to
# stop. Every "cannot prove it" case in the file fails red; this one included,
# bounded to a single block by stop_hook_active.
#
# THE KILL SWITCH FAILS OPEN, on purpose. Claude Code offers no way to accept a
# plugin but decline its hooks, so an explicit off switch is the only fair
# answer to "I want the skills without the Stop hook".

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

# --- a hook that cannot find its own run_gates.sh -----------------------------
# Copy the hook somewhere with no sibling lib/, so self-location resolves to a
# path that does not exist. This is a broken install of the hook's own wiring,
# not a repo it can gate.
fake_plugin="$CASE_TMP/fakeplugin/hooks"
mkdir -p "$fake_plugin"
cp "$HOOK" "$fake_plugin/readiness-gate.sh"

repo="$(mkrepo broken_install)"
write_task "$repo" implementing
write_gates "$repo" 0          # green — so only the broken wiring can fail it

run_hook_script "$fake_plugin/readiness-gate.sh" "$repo"
assert_rc 2 "$HOOK_RC" "an unreachable run_gates.sh fails red, not open"
assert_contains "$HOOK_OUT" "broken hook install" "the message names the real cause"
assert_file_contains "$(hooklog "$repo")" "decision=fire.*verdict=RED" \
  "the broken install is recorded in the audit log"

# --- the kill switch ----------------------------------------------------------
off="$(mkrepo kill_switch)"
write_task "$off" implementing
write_gates "$off" 1           # red — the switch must win anyway

HOOK_OUT="$(hook_payload false "$off" \
  | GANTRY_READINESS_GATE=off CLAUDE_PROJECT_DIR="$off" bash "$HOOK" 2>&1)"
HOOK_RC=$?
assert_rc 0 "$HOOK_RC" "GANTRY_READINESS_GATE=off disables the hook entirely"
assert_gate_not_run "$off" "the disabled hook runs no gate"
assert_path_absent "$off/.claude/artifacts" \
  "the disabled hook writes nothing into the repo"

finish
