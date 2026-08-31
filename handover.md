# Handover — fix/detector-inherited-task-and-plan-order

Deferred from *Report an inherited task as inherited, stop calling the hook armed, and write Out of
scope after the code study*. The change itself is complete and the gate is green; these are
findings it did not absorb.

## `PHASE:` and `NEXT:` still read an inherited task as already shipped

**What it is.** `lib/detect_stage.sh` now reports `TASK:inherited` for the previous, merged
contract that arrives in every freshly branched worktree — but that same `task.md` carries
`status: shipped`, and `PHASE` is derived from `STATUS` alone. So the detector emits
`TASK:inherited` and `PHASE:done NEXT:none — already shipped` in one snapshot, which is
self-contradicting on its face.

It matters because `TASK:` is not what the other phases route on. `skills/plan/SKILL.md` is the
only consumer taught the new value; `skills/implement/SKILL.md`, `skills/review/SKILL.md` and
`skills/grill/SKILL.md` all route on `PHASE`/`STATUS`. Run any of them directly on a
freshly-branched worktree — without going through `plan` first — and they are still told the work
is finished.

**Why it was deferred.** Out of the contract, which is scoped to the `TASK:` line and the plan
phase. Deriving `PHASE` from the new value changes how `implement`, `review` and `ship` route,
which is a behavioural change to four skills and wants its own plan and its own critique. It is
also partly self-limiting: the drivers reach `plan` first, `plan` supersedes the file, and from
that point the snapshot is correct.

**What was already established.** The `PHASE` derivation is a single `case "$STATUS"` in
`lib/detect_stage.sh`; `TASK` is not consulted anywhere in it, and this change deliberately did not
start consulting it. A grep for `TASK:` across `skills/`, `docs/`, `hooks/`, `lib/` and `tests/`
found four routers in total: `plan` (updated), `handover` (updated to accept both values),
`auto-unattended`'s never-clobber rule (updated), and `review`, which branches only on
`TASK:absent` and therefore treats `inherited` exactly as it treats `present` — correct today, and
checked rather than assumed.

**Next action.** Decide the one question first, because the code is trivial either way: should
`PHASE` report `plan` when `TASK:inherited`, or should `PHASE` keep reporting what `STATUS` says
and the *consumers* learn to check `TASK:` themselves? The first is one line in the `case` and
changes what four skills do; the second is four edits and leaves the detector honest. Write that
choice down before touching either.

## `plan.md` is inherited on exactly the same terms and gets no third value

**What it is.** `plan.md` is committed with every PR for the same reason `task.md` is, so a
freshly branched worktree inherits both. Only `task.md` gained a third value. `PLAN:present` is
therefore true on a clean branch in the same misleading way `TASK:present` was, and
`skills/grill/SKILL.md` routes `PLAN:present` to "continue, whatever `STATUS` says" — so
`/gantry:grill` run before `/gantry:plan` on a clean branch will dispatch a critic against the
*previous* merged plan and return findings about work that already shipped.

**Why it was deferred.** The contract covers `task.md`. It is also not a straight copy of the
`task.md` rule: `plan.md` has no frontmatter and no `status:`, so the terminal-status condition —
which is half of what makes the `task.md` detection safe — has no equivalent. A `plan.md`
byte-identical to the merge-base copy is weaker evidence on its own, and deciding what would make
it strong enough is a design question, not an implementation one.

**What was already established.** `open_questions_forks()` and the new `task_is_inherited()` are
both self-contained functions that share no code with `frontmatter_status()`, which is the
constraint any addition here has to respect — `scripts/verify.sh` diffs that one function
byte-for-byte against `hooks/readiness-gate.sh`'s copy, so it must not be touched. A `plan.md`
check would follow the same shape and could reuse `inherited_base_rev()` as-is.

**Next action.** Settle whether byte-identity alone is sufficient evidence for `plan.md` given
there is no status to corroborate it. If it is, `PLAN:inherited` is a five-line function reusing
`inherited_base_rev()`; if it is not, the honest answer may be to leave `plan.md` alone and instead
have `grill` refuse when `TASK:inherited`, which is one bullet in `skills/grill/SKILL.md` and needs
no new detection at all.

## The renamed `HOOK:` value has not been checked against a live hook

**What it is.** `HOOK:` now reports `conditions-met`/`conditions-unmet`, and the whole point of the
rename is that the detector *cannot* see whether the hook is registered. Nothing in this change
verifies that the renamed value lines up with what a registered hook actually does on a real run,
because nothing in this repository can: the fixtures drive `hooks/readiness-gate.sh` directly
rather than through the harness that registers it.

**Why it was deferred.** It needs a human watching a real session — it is unautomatable here by
construction, and it is recorded in `task.md`'s *How to verify* as a human-only check rather than
as an acceptance criterion for that reason.

**What was already established.** The firing conditions themselves are pinned by
`tests/cases/hook_inert_unless_armed.sh`, `hook_arms_and_blocks.sh` and `hook_worktree_root.sh`,
all of which assert on the hook's exit code and on whether the gate ran — never on the detector's
string, which is why none of them needed changing. So the *conditions* are tested; what is untested
is that the detector's report of them matches the hook's behaviour in a live run.

**Next action.** On the next real unattended run in a repo with `.claude/gates.sh`, at the moment
`task.md` says `status: implementing`, run `bash lib/detect_stage.sh` and then check
`.claude/artifacts/gate-hook.log` for an entry from the same stop. Matching `conditions-met` with a
log line closes it; `conditions-met` with no log line means the hook is not registered in that
environment, which is exactly the gap the rename exists to make visible.
