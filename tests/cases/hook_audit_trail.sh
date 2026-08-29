#!/usr/bin/env bash
#
# The audit trail is the whole mitigation for the hook's acknowledged limit:
# its trigger is task.md's `status:`, a file the model can write, so a bypass
# is not prevented — it is made visible after the fact. Two properties have to
# hold for that argument to be worth anything.
#
# 1. THE START IS LOGGED BEFORE THE GATE RUNS. The one path where a stop
#    proceeds un-gated is a gate that hangs until the harness kills the hook at
#    its 300s timeout. If the only log write happens after run_gates.sh
#    returns, that path leaves no evidence at all — the single case the trail
#    exists for is the single case it misses. Writing an `arm` line first turns
#    a killed hook into a dangling `arm` with no outcome: greppable, and
#    unambiguous.
#
# 2. AN UNARMED REPO IS WRITTEN TO NOT AT ALL. The hook is registered for every
#    Stop and SubagentStop in every session, in every repository. If it creates
#    .claude/artifacts/ before evaluating its firing conditions, then installing
#    gantry means every repo you ever open acquires a directory and a log line
#    for a plugin it never opted into.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

# --- 1. the arm line is written before the gate is invoked -------------------
# The fixture gate inspects the audit log while it runs: if the arm line is
# already there, it leaves a marker. That proves the ordering without a sleep,
# a kill, or a race.
armed="$(mkrepo arm_ordering)"
write_task "$armed" implementing
write_gates_body "$armed" <<'GATE'
#!/usr/bin/env bash
root="$(git rev-parse --show-toplevel)"
if grep -q 'decision=arm' "$root/.claude/artifacts/gate-hook.log" 2>/dev/null; then
  touch "$root/arm-line-was-already-written"
fi
exit 1
GATE

run_hook "$armed"
assert_rc 2 "$HOOK_RC" "the red gate still blocks"
assert_path_present "$armed/arm-line-was-already-written" \
  "the arm line is on disk before the gate starts"
assert_file_contains "$(hooklog "$armed")" "decision=arm" \
  "the audit log carries an arm line"
assert_file_contains "$(hooklog "$armed")" "decision=fire.*verdict=RED" \
  "and the matching outcome line"

# --- 2a. a repo that never opted in is not written to ------------------------
plain="$(mkrepo untouched)"
i=0
while [ "$i" -lt 10 ]; do
  run_hook "$plain"
  assert_rc 0 "$HOOK_RC" "stop $((i + 1)) in an unarmed repo passes"
  i=$((i + 1))
done
assert_path_absent "$plain/.claude" \
  "ten stops in an unarmed repo create no .claude directory"

# --- 2b. a task.md alone is not an opt-in ------------------------------------
task_only="$(mkrepo task_only)"
write_task "$task_only" implementing
run_hook "$task_only"
assert_rc 0 "$HOOK_RC" "a task.md with no gate leaves the hook inert"
assert_path_absent "$task_only/.claude" \
  "a task.md alone does not cause a write"

# --- 2c. a gate file alone is not an opt-in either ---------------------------
gate_only="$(mkrepo gate_only)"
write_gates "$gate_only" 1
run_hook "$gate_only"
assert_rc 0 "$HOOK_RC" "a gate with no task.md leaves the hook inert"
assert_path_absent "$gate_only/.claude/artifacts" \
  "a gate file alone does not cause a write"

# --- 2d. but an ARMED repo still logs its skips ------------------------------
# The fix above must not over-correct into silence. Once a repo has opted in,
# every invocation is still accounted for — including the ones that decline to
# fire, which is what makes a bypass visible.
opted_in="$(mkrepo opted_in)"
write_task "$opted_in" implemented
write_gates "$opted_in" 1

run_hook "$opted_in"
assert_rc 0 "$HOOK_RC" "an opted-in repo at the wrong status stays inert"
assert_file_contains "$(hooklog "$opted_in")" "decision=skip.*status:implemented" \
  "but the skip is still recorded, with its reason"

finish
