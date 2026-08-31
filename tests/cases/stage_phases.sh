#!/usr/bin/env bash
#
# detect_stage.sh is the single reader of "where is this task". The phase
# skills are individually invocable, so none of them may infer its position
# from the conversation — a fresh session, a sub-agent and a resumed one all
# have to reach the same answer, and they reach it here.
#
# It also reports HOOK:conditions-met/conditions-unmet — the readiness hook's
# firing conditions, which is as much as the detector can establish, since it
# cannot see whether the hook is registered. A phase reports that value to say
# plainly whether a run was enforced or merely self-policed, and blurring those
# two is the one lie the chain cannot absorb, so the line is asserted rather
# than trusted.
#
# And TASK:present/absent/inherited, where `inherited` is the merged contract
# that arrives in every freshly branched worktree because task.md is committed
# with the PR. The asymmetry there is the point and it is what these fixtures
# pin: reading a live task as inherited destroys work, so every condition the
# detector cannot establish has to land on `present`.

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

# --- the firing-conditions report ---------------------------------------------
rm -f "$repo/plan.md"
write_task "$repo" implementing
run_stage "$repo"
assert_contains "$STAGE_OUT" "GATES:absent" "no .claude/gates.sh is reported"
assert_contains "$STAGE_OUT" "HOOK:conditions-unmet" \
  "implementing alone does not meet the firing conditions"

write_gates "$repo" 0
run_stage "$repo"
assert_contains "$STAGE_OUT" "GATES:present" "the gate file is reported"
assert_contains "$STAGE_OUT" "HOOK:conditions-met" \
  "gate plus implementing is what meets them"

write_task "$repo" implemented
run_stage "$repo"
assert_contains "$STAGE_OUT" "HOOK:conditions-unmet" "any other status unmeets them again"

# --- the inherited contract ---------------------------------------------------
# task.md is committed with every PR, so a branch cut from the base is born
# holding the PREVIOUS task's finished contract. `inherited` is that state.
#
# Two traps these fixtures are built to avoid, both of which produce a suite
# that passes while proving nothing:
#
#   1. mkrepo takes its branch name from the developer's init.defaultBranch, so
#      every fixture below NAMES its base branch. On a machine set to `trunk`
#      the base would not resolve and the positive case would fail for a reason
#      that has nothing to do with the change.
#   2. The negative cases are otherwise-POSITIVE repos with exactly one
#      condition removed. Built from a bare mkrepo, task.md would be missing at
#      the merge-base too, and the assertion would pass with the degradation
#      logic deleted entirely — a false green on the one asymmetry the whole
#      design rests on.

# The positive case: base branch, a merged contract committed on it, a branch
# cut from that, file untouched.
inh="$(mkrepo inherited)"
git -C "$inh" branch -m master >/dev/null 2>&1
write_task "$inh" shipped
commit_all "$inh" "the merged contract"
git -C "$inh" checkout -q -b fix/next >/dev/null 2>&1
run_stage "$inh"
assert_rc 0 "$STAGE_RC" "the inherited check leaves the exit code alone"
assert_contains "$STAGE_OUT" "TASK:inherited" \
  "a branch cut from the base carries the merged contract"
assert_not_contains "$STAGE_OUT" "TASK:present" \
  "and does not also emit the value it replaced"

# The byte guard, isolated — and this is the case the whole asymmetry rests on.
# The status stays `shipped` and only the BODY changes, so every other condition
# still holds: attached HEAD, resolvable base, a merge-base, and a task.md
# present there. Nothing but the byte comparison can reject it.
#
# Without this fixture the comparison could be deleted outright and the suite
# would still pass, because every other case is rejected by an earlier guard —
# and the failure it would let through is the unrecoverable one: a live
# `shipped` task on a branch routed to a clean start and overwritten.
write_task_raw "$inh" <<'EDITED'
---
status: shipped
---

# task

Same status, different body — this one has been worked on.
EDITED
run_stage "$inh"
assert_contains "$STAGE_OUT" "TASK:present" \
  "same status but edited bytes is a task in flight, not an inherited one"

# Superseded in place the ordinary way — bytes and status both change.
write_task "$inh" planning
run_stage "$inh"
assert_contains "$STAGE_OUT" "TASK:present" \
  "superseding it in place makes it a task in flight again"

# task.md absent from the merge-base commit: the branch introduced it, so there
# is nothing it could have been inherited from.
new="$(mkrepo new-contract)"
git -C "$new" branch -m master >/dev/null 2>&1
git -C "$new" checkout -q -b fix/next >/dev/null 2>&1
write_task "$new" shipped
run_stage "$new"
assert_contains "$STAGE_OUT" "TASK:present" \
  "a task.md the branch introduced is not inherited from the base"

# The status guard, isolated. The status lives INSIDE the file, so identical
# bytes and a non-terminal status is only reachable when the committed copy is
# itself non-terminal: here the bytes match perfectly and only `status:` differs
# from `shipped`, so nothing but the status guard can reject it.
liv="$(mkrepo live-contract)"
git -C "$liv" branch -m master >/dev/null 2>&1
write_task "$liv" planning
commit_all "$liv" "a contract still in flight"
git -C "$liv" checkout -q -b fix/next >/dev/null 2>&1
run_stage "$liv"
assert_contains "$STAGE_OUT" "TASK:present" \
  "bytes identical to the merge-base but a non-terminal status is not inherited"

# No resolvable base. Identical to the positive case in every other respect —
# the bytes match and a merge-base exists — with only the base branch renamed
# out of develop/main/master and no remote to declare one.
nob="$(mkrepo no-base)"
git -C "$nob" branch -m trunk >/dev/null 2>&1
write_task "$nob" shipped
commit_all "$nob" "the merged contract"
git -C "$nob" checkout -q -b fix/next >/dev/null 2>&1
run_stage "$nob"
assert_contains "$STAGE_OUT" "TASK:present" \
  "no resolvable base degrades to present, never to inherited"

# The base must be merge-based as `origin/<name>`, not as the bare branch name.
# This is the case that decides whether the feature works at all in practice:
# gantry:worktree cuts every worktree from origin/<parent> and treats
# fast-forwarding the local ref as a convenience it may skip, so a local base
# that lags origin is the NORMAL state, not an edge case. Against the local ref
# the merge-base lands on an older commit carrying a DIFFERENT merged task.md,
# the bytes differ, and the answer silently becomes `present` forever.
#
# So: a clone whose origin/master has moved on while its local master has not,
# with the branch cut from origin/master. Only a detector that resolves
# origin/master gets this right; every all-local fixture above passes either way.
up="$(mkrepo upstream)"
git -C "$up" branch -m master >/dev/null 2>&1
write_task "$up" shipped
commit_all "$up" "the first merged contract"
dn="$CASE_TMP/downstream"
# -o origin, not the default: clone.defaultRemoteName is global config, and this
# suite does not read the developer's. Without it, a machine that renames the
# default remote has no refs/remotes/origin/master and this case fails for a
# reason that has nothing to do with the detector.
git clone -q -o origin "$up" "$dn" >/dev/null 2>&1
write_task_raw "$up" <<'SECOND'
---
status: shipped
---

# a different, later merged contract
SECOND
commit_all "$up" "the second merged contract"
git -C "$dn" fetch -q origin >/dev/null 2>&1   # origin/master advances; local master does not
git -C "$dn" checkout -q -b fix/next origin/master >/dev/null 2>&1
run_stage "$dn"
assert_contains "$STAGE_OUT" "TASK:inherited" \
  "the base resolves through origin, so a stale local ref does not defeat it"

# Detached HEAD, on a commit reachable from the base. Base resolution succeeds
# here and so does merge-base, so only the explicit attached-HEAD guard stands
# between this and a wrong `inherited`.
det="$(mkrepo detached)"
git -C "$det" branch -m master >/dev/null 2>&1
write_task "$det" shipped
commit_all "$det" "the merged contract"
git -C "$det" checkout -q --detach HEAD >/dev/null 2>&1
run_stage "$det"
assert_contains "$STAGE_OUT" "TASK:present" \
  "a detached HEAD degrades to present, never to inherited"

# --- it takes no arguments ----------------------------------------------------
STAGE_OUT="$(cd "$repo" && bash "$DETECT_STAGE" --nope 2>&1)"
STAGE_RC=$?
assert_rc 2 "$STAGE_RC" "an argument is a usage error"

finish
