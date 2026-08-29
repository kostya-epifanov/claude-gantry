---
name: review
description: Get an independent review of the diff, then act on it — fix what is clearly in scope, re-run the gate, and hand the rest to /gantry:handover rather than quietly widening the change. Use when the user types "/gantry:review", or asks to review the diff, check the changes, or get a second opinion before shipping.
argument-hint: ""
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Skill, Agent, AskUserQuestion
---

# gantry:review

Review the change, then do something about it. The reviewing half is worth little without the
triage half: a list of findings nobody acted on is not a review, it is a receipt.

## Steps

### 1. Detect the stage and get the diff

`$GANTRY` is this skill's plugin root — resolve it from this file's own location rather than
hardcoding a path.

```bash
bash "$GANTRY/lib/detect_stage.sh"
```

- `PHASE:not-a-repo` → stop.
- `TASK:absent` → warn: with no contract there is nothing to check the change *against*, so the
  review is against general quality only. Continue; say so in the report.
- `STATUS:planned` / `grilled` → nothing has been implemented yet. If the tree is clean there is
  nothing to review — say so and name `NEXT`. If it is dirty, someone worked by hand; review that,
  and say that is what happened.

Then get the diff. **The tree is usually uncommitted at this point** — `gantry:ship` commits, and
it has not run yet — so a three-dot range against the base is empty and will make an unreviewed
change look clean:

```bash
git diff <BASE>            # committed + working-tree changes vs the base
git status --short         # untracked files the diff above cannot show
```

Read the untracked files too. A new file nobody reviewed is the easiest place for a defect to hide.

### 2. Get an independent review

Three tiers, in order. **Say which one ran** — the tiers are not equivalent, and the report must
not imply more independence than the run had.

1. **`/code-review`** — purpose-built, and it already knows this harness. **Invoke it; do not
   survey for it first.** It ships with Claude Code, so present is the default assumption and an
   invocation that errors is the only evidence that it is absent. Falling through *because you did
   not check* is the failure this ordering exists to prevent: tier 2 reads like a review in the
   report, so a silent downgrade costs the better reviewer and leaves no trace.

   Name the effort level — `/code-review high`. With none given it reuses whatever level was typed
   last in the session, which makes two runs of this phase incomparable for a reason that has
   nothing to do with the diff. Do **not** pass `ultra`: it is billed and user-triggered, and
   `gantry:auto-unattended` has nobody present to authorise it. Do **not** pass `--fix` either —
   it applies every finding, and step 3 below is the whole reason this skill decides which
   findings the change is allowed to absorb.

   `gantry:ship` **does** pass `--fix`, and that is not a contradiction: its review stage runs only
   for a caller who has no `task.md` to triage against and no step 3 to protect. The two never both
   run — the drivers pass `--reviewed` to ship precisely so this phase's deferrals are not
   reopened and applied by `--fix`.
2. **A review sub-agent** (Agent tool): the repo's `.claude/agents/reviewer.md` if it defines one,
   otherwise `gantry-reviewer`. Give it the worktree path, the base branch, and `task.md`'s path —
   let it read the diff itself. Ask for correctness defects first, then reuse and simplification,
   each with a concrete failure or a concrete saving.
3. **Self-review**, only if neither is available, and **disclose it**. You reviewing your own
   change is the weakest tier by a wide margin; the value of saying so is that the reader can
   weigh it correctly.

Whichever tier ran, check the findings against the repo yourself before acting. Reviewers,
including good ones, report things that are not true.

### 3. Triage every finding

Read `task.md`'s **Out of scope** section first — it is the boundary that makes this decision
something other than taste. Then sort each surviving finding:

- **Address now** — a defect in the code this change introduced, or a small clear-cut cleanup
  inside the change's own footprint. Fix it.
- **Defer** — real, but outside this task: a pre-existing bug the diff merely revealed, a
  refactor the finding would require, anything the contract excludes, anything large enough to
  need its own plan. **Do not fix these.** Widening a change to absorb what review turned up is how
  a focused diff becomes an unreviewable one.
- **Drop** — checked and not actually true, or pure style against a convention the repo does not
  hold. Say how many you dropped; do not list them all.

The dividing line is scope, not difficulty. A one-line fix outside the contract still gets
deferred; a genuinely fiddly fix to code this change introduced still gets made.

Where the call is honestly ambiguous, ask — **AskUserQuestion**, one round, with the findings
described in terms of what each costs. With no human present, defer rather than expand: a deferred
finding is written down and recoverable, an unrequested refactor is neither.

### 4. Fix what you kept, then re-prove it

Make the address-now fixes, then **re-run the gate** — a fix made after the gate went green is
unproven code:

```bash
bash "$GANTRY/lib/run_gates.sh"            # supervised
bash "$GANTRY/lib/run_gates.sh" --strict   # unattended
```

Same exit-code contract as `/gantry:implement`: `0` green · `1`+ red · `2` could not run · `3`
`NO-GATES` under `--strict`. Red here means your fix broke something — treat it exactly as
`implement` does, capped at 2 attempts unattended, stop and report supervised.

### 5. Hand over what you deferred

If anything was deferred, **invoke `gantry:handover`** and let it write `handover.md`. Pass it the
findings, why each is out of scope, and what the next person should do. Do not write the file
yourself — the handover skill owns its shape, and `/gantry:handover` typed by hand must produce the
same artifact this does.

Nothing deferred → no `handover.md`. An empty handover file is noise in the diff.

### 6. Record the status

Set `task.md` frontmatter to `status: reviewed`.

If review found something that makes the change unsafe to ship at all, set `status: blocked`
instead, hand it over, and say so. Blocking here is cheap; blocking after the merge is not.

## Report

Which review tier ran — named plainly, self-review disclosed as self-review. If tier 1 did not run,
say what happened when you invoked it; "unavailable" with no cause is how a downgrade hides. How
many findings came back, how many were addressed, deferred, and dropped. The gate's exit code if
you re-ran it. The `handover.md` path if one was written. End by naming the next command:
`/gantry:ship`.
