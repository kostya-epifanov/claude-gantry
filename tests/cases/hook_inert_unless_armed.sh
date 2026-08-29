#!/usr/bin/env bash
#
# The hook installs registered but INERT. It fires only when all three hold:
# task.md exists, .claude/gates.sh exists, and task.md's frontmatter says
# exactly `status: implementing`.
#
# The narrowness of that third condition is deliberate — the hook must not fire
# while planning is still under way, and widening the matcher is the easiest
# way to make it fire constantly and get switched off. So every other status in
# the vocabulary is asserted here, not just a representative one.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

# --- no task.md, but a gate present ------------------------------------------
no_task="$(mkrepo no_task)"
write_gates "$no_task" 1

run_hook "$no_task"
assert_rc 0 "$HOOK_RC" "no task.md leaves the hook inert"
assert_gate_not_run "$no_task" "no task.md means the gate never runs"

# --- a task.md at implementing, but no gate ----------------------------------
# Creating .claude/gates.sh IS the opt-in. Without it there is nothing to run
# and nothing to enforce, however the task file reads.
no_gates="$(mkrepo no_gates)"
write_task "$no_gates" implementing

run_hook "$no_gates"
assert_rc 0 "$HOOK_RC" "no .claude/gates.sh leaves the hook inert"
assert_gate_not_run "$no_gates" "no gate file means the gate never runs"

# --- every status that is not exactly `implementing` -------------------------
other="$(mkrepo other_statuses)"
write_gates "$other" 1

for status in planning planned grilled implemented reviewed shipped blocked; do
  write_task "$other" "$status"
  run_hook "$other"
  assert_rc 0 "$HOOK_RC" "status:$status leaves the hook inert"
done

assert_gate_not_run "$other" "no non-implementing status ever ran the gate"

# --- and the armed value still fires, against the same fixture ---------------
# Without this the case above would pass just as well if the hook were broken
# and never fired at all.
write_task "$other" implementing
run_hook "$other"
assert_rc 2 "$HOOK_RC" "status:implementing does arm, against the same repo"
assert_gate_ran "$other" "the armed run did execute the gate"

finish
