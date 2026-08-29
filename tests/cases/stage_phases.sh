#!/usr/bin/env bash
#
# detect_stage.sh is the single reader of "where is this task". The phase
# skills are individually invocable, so none of them may infer its position
# from the conversation — a fresh session, a sub-agent and a resumed one all
# have to reach the same answer, and they reach it here.
#
# It also reports HOOK:armed/inert, which is how a phase can say plainly
# whether a run was actually enforced or merely self-policed. Blurring those
# two is the one lie the chain cannot absorb, so the line is asserted rather
# than trusted.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

repo="$(mkrepo stages)"

check_phase() {  # check_phase <status> <expected-phase>
  write_task "$repo" "$1"
  run_stage "$repo"
  assert_contains "$STAGE_OUT" "PHASE:$2" "status:$1 resolves to PHASE:$2"
}

check_phase planning     plan
check_phase planned      grill
check_phase grilled      implement
check_phase implementing implement
check_phase implemented  review
check_phase reviewed     ship
check_phase shipped      "done"
check_phase blocked      blocked

# --- the fallbacks, for a hand-written or half-edited task.md ----------------
rm -f "$repo/task.md"
run_stage "$repo"
assert_contains "$STAGE_OUT" "PHASE:plan" "no task.md at all resolves to plan"
assert_contains "$STAGE_OUT" "TASK:absent" "and reports the artifact as absent"

# A plan with no recorded status is assumed not carried out: re-implementing is
# recoverable, skipping is not.
printf '# plan\n' >"$repo/plan.md"
run_stage "$repo"
assert_contains "$STAGE_OUT" "PHASE:implement" "a plan.md with no status resolves to implement"

# --- the arming report --------------------------------------------------------
rm -f "$repo/plan.md"
write_task "$repo" implementing
run_stage "$repo"
assert_contains "$STAGE_OUT" "GATES:absent" "no .claude/gates.sh is reported"
assert_contains "$STAGE_OUT" "HOOK:inert" "implementing alone does not arm the hook"

write_gates "$repo" 0
run_stage "$repo"
assert_contains "$STAGE_OUT" "GATES:present" "the gate file is reported"
assert_contains "$STAGE_OUT" "HOOK:armed" "gate plus implementing is what arms it"

write_task "$repo" implemented
run_stage "$repo"
assert_contains "$STAGE_OUT" "HOOK:inert" "any other status disarms it again"

# --- it takes no arguments ----------------------------------------------------
STAGE_OUT="$(cd "$repo" && bash "$DETECT_STAGE" --nope 2>&1)"
STAGE_RC=$?
assert_rc 2 "$STAGE_RC" "an argument is a usage error"

finish
