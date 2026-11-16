#!/usr/bin/env bash
#
# The heavy slot is a box-wide counting lock that run_gates.sh takes before any
# check, so concurrent gates cannot take a small box out of memory. Its contract
# is three things: the wrapped command's exit code comes back verbatim, a gate
# that finds every slot held by a live process waits (and says so) rather than
# running, and a slot whose holder is dead is taken back rather than wedging
# every later gate. And run_gates.sh must go through it exactly once — a nested
# gate that tried to take a second slot would wait forever on its own parent.
#
# The holder in these fixtures is a background `sleep` whose PID is written into
# a slot file. Every holder is killed AND reaped here: `kill -0` succeeds on a
# zombie, so an unreaped holder would look live forever and hang the suite. The
# waiter runs in the background with a deadline for the same reason.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

# This case is the one that exercises the lock, so it undoes lib.sh's default.
unset GANTRY_HEAVY_SLOT_HELD GANTRY_HEAVY_SLOTS
GANTRY_HEAVY_SLOT_DIR="$CASE_TMP/slots"
export GANTRY_HEAVY_SLOT_DIR

reset_slots() { rm -rf "$GANTRY_HEAVY_SLOT_DIR"; mkdir -p "$GANTRY_HEAVY_SLOT_DIR"; }

# --- exit code and environment -----------------------------------------------
reset_slots
out="$(bash "$HEAVY_SLOT" -- bash -c 'exit 7' 2>&1)"; rc=$?
assert_rc 7 "$rc" "the wrapped command's exit code comes back verbatim"
assert_contains "$out" "heavy-slot: acquired slot=0 slots=1 waited=" "and the acquired line is printed"

out="$(bash "$HEAVY_SLOT" -- true 2>&1)"; rc=$?
assert_rc 0 "$rc" "a green command stays green"

out="$(bash "$HEAVY_SLOT" -- bash -c 'echo "held=$GANTRY_HEAVY_SLOT_HELD"; cat "$GANTRY_HEAVY_SLOT_HELD"' 2>&1)"
assert_contains "$out" "held=$GANTRY_HEAVY_SLOT_DIR/slot.0" "the child sees GANTRY_HEAVY_SLOT_HELD naming its slot"
assert_path_absent "$GANTRY_HEAVY_SLOT_DIR/slot.0" "and the slot is released afterwards"

bash "$HEAVY_SLOT" >/dev/null 2>&1; rc=$?
assert_rc 2 "$rc" "no command is a usage error"

# --- a live holder makes the next run wait -----------------------------------
reset_slots
sleep 60 & holder=$!
printf '%s 0 fixture-root\n' "$holder" >"$GANTRY_HEAVY_SLOT_DIR/slot.0"
wout="$CASE_TMP/wait.out"; wrc="$CASE_TMP/wait.rc"
rm -f "$wout" "$wrc"
( bash "$HEAVY_SLOT" -- true >"$wout" 2>&1; echo $? >"$wrc" ) &
n=0
while ! grep -q 'waiting' "$wout" 2>/dev/null && [ "$n" -lt 50 ]; do sleep 0.2; n=$((n + 1)); done
assert_file_contains "$wout" "waiting after .* 1/1 busy: slot0 pid=$holder .*root=fixture-root" \
  "with every slot held by a live process it waits and names the holder"
assert_path_absent "$wrc" "and has not run the command"
sleep 1
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
n=0
while [ ! -f "$wrc" ] && [ "$n" -lt 20 ]; do sleep 1; n=$((n + 1)); done
if [ -f "$wrc" ]; then
  assert_rc 0 "$(cat "$wrc")" "once the holder is gone the waiter acquires and runs"
  assert_file_contains "$wout" "acquired slot=0 slots=1 waited=[1-9][0-9]*s" "and reports a non-zero wait"
else
  _fail "the waiter never acquired after its holder died (20 s deadline)"
fi
wait 2>/dev/null

# --- a dead holder's slot is taken back --------------------------------------
reset_slots
sleep 0 & dead=$!; wait "$dead"
printf '%s 0 fixture-root\n' "$dead" >"$GANTRY_HEAVY_SLOT_DIR/slot.0"
out="$(bash "$HEAVY_SLOT" -- true 2>&1)"; rc=$?
assert_rc 0 "$rc" "a slot held by a dead PID does not block"
assert_contains "$out" "acquired slot=0" "it is stolen back"
assert_not_contains "$out" "waiting" "without waiting"

# --- counting, the create/write instant, and the kill switch -----------------
reset_slots
sleep 60 & holder=$!
printf '%s 0 fixture-root\n' "$holder" >"$GANTRY_HEAVY_SLOT_DIR/slot.0"
out="$(GANTRY_HEAVY_SLOTS=2 bash "$HEAVY_SLOT" -- true 2>&1)"
assert_contains "$out" "acquired slot=1 slots=2" "with two slots and one held, the second is taken at once"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

reset_slots
: >"$GANTRY_HEAVY_SLOT_DIR/slot.0"
out="$(GANTRY_HEAVY_SLOTS=2 bash "$HEAVY_SLOT" -- true 2>&1)"
assert_contains "$out" "acquired slot=1 slots=2" "a fresh empty slot (holder mid-write) counts as live, not dead"

reset_slots
out="$(GANTRY_HEAVY_SLOTS=0 bash "$HEAVY_SLOT" -- bash -c 'echo "held=$GANTRY_HEAVY_SLOT_HELD"' 2>&1)"
assert_contains "$out" "held=disabled" "GANTRY_HEAVY_SLOTS=0 disables the lock"
assert_path_absent "$GANTRY_HEAVY_SLOT_DIR/slot.0" "and takes no slot"

out="$(GANTRY_HEAVY_SLOTS=lots bash "$HEAVY_SLOT" -- true 2>&1)"
assert_contains "$out" "not a count; using 1" "a non-count is noted and read as 1"

# --- run_gates.sh goes through it once ---------------------------------------
reset_slots
repo="$(mkrepo gated)"
write_gates_body "$repo" <<'EOF'
#!/usr/bin/env bash
echo "inner-held=${GANTRY_HEAVY_SLOT_HELD:-none}"
exit 0
EOF
run_gate "$repo" --strict
assert_rc 0 "$GATE_RC" "run_gates.sh under the slot still passes a green repo"
assert_contains "$GATE_OUT" "heavy-slot: acquired slot=0" "run_gates.sh takes a heavy slot"
assert_contains "$GATE_OUT" "inner-held=$GANTRY_HEAVY_SLOT_DIR/slot.0" "and the gate runs holding it"
assert_path_absent "$GANTRY_HEAVY_SLOT_DIR/slot.0" "and releases it"

write_gates "$repo" 1
run_gate "$repo"
assert_rc 1 "$GATE_RC" "a red gate is still red through the slot"

GATE_OUT="$(cd "$repo" && GANTRY_HEAVY_SLOT_HELD=outer bash "$RUN_GATES" 2>&1)"
assert_not_contains "$GATE_OUT" "heavy-slot" "a nested gate (slot already held) does not take another"

assert_file_contains "$GANTRY_ROOT/docs/ARCHITECTURE.md" "GANTRY_HEAVY_SLOTS" \
  "docs/ARCHITECTURE.md documents the heavy slot"

finish
