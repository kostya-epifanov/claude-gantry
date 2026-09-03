---
name: review
description: Get an independent review of the diff, verify every finding against the repo, then triage what survives against the task contract — handing what's out of scope to /gantry:handover rather than quietly widening the change. Read-only unless you pass --fix, which applies the findings triage keeps. Pass --tier medium|high|xhigh|max to set the depth (default high). Use when the user types "/gantry:review", or asks to review the diff, check the changes, or get a second opinion before shipping.
argument-hint: [--tier <medium|high|xhigh|max>] [--fix]
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Skill, Agent, AskUserQuestion
---

# gantry:review

Review the change, then do something about it. The reviewing half is worth little without the
triage half: a list of findings nobody acted on is not a review, it is a receipt.

**Read-only by default.** With no `--fix`, this skill makes **no change to the code under review**.
It still writes gantry's own artifacts — `task.md`'s status, always, and `handover.md` when
something is deferred — because those are the chain's bookkeeping rather than the change. `--fix`
is what licenses it to edit the code.

**`--tier <medium|high|xhigh|max>`**, default `high`. The depth of the `/code-review` run in step 2.
See that step for what the values mean and which are refused.

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
- `TASK:inherited` → **treat it as `absent`, not as `present`.** The `task.md` on disk is the
  previous, merged task's contract — a freshly branched worktree is born holding it — so its
  acceptance criteria and *Out of scope* describe a different change. Reviewing this diff against
  them triages findings by the wrong boundary. Warn as above and say which it was.
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

Three **sources**, in order of independence. **Say which one ran** — they are not equivalent, and
the report must not imply more independence than the run had. (These are sources, not "tiers":
`--tier` is the effort level passed to source 1, and conflating the two makes the report ambiguous
about the thing it exists to record.)

1. **`/code-review`** — purpose-built, and it already knows this harness. **Invoke it; do not
   survey for it first.** It ships with Claude Code, so present is the default assumption and an
   invocation that errors is the only evidence that it is absent. Falling through *because you did
   not check* is the failure this ordering exists to prevent: source 2 reads like a review in the
   report, so a silent downgrade costs the better reviewer and leaves no trace.

   Name the effort level explicitly — with none given it reuses whatever was typed last in the
   session, which makes two runs of this phase incomparable for a reason that has nothing to do
   with the diff:

   ```
   /code-review <tier>          # <tier> = --tier's value, default high
   ```

   **Validate `--tier` before dispatching**, and this skill is the only place that does — `gantry:ship`
   forwards its `--review=<tier>` value here unvalidated rather than keeping a second copy of the
   list that could drift out of step with this one.

   - `medium` · `high` · `xhigh` · `max` → pass it through.
   - `ultra` → **refuse by name.** It is billed and user-triggered, and `gantry:auto-unattended` has
     nobody present to authorise it. Say that is why, rather than reporting it as an invalid value.
   - anything else → **stop and name the valid values.** Dispatch nothing. Do not fall back to
     `high`: an errored invocation is exactly what step 2 reads as "`/code-review` is unavailable",
     so a typo'd tier would silently downgrade the whole run to source 2.

   Do **not** pass `--fix`. It applies every finding, and steps 3 and 4 below are the whole reason
   this skill decides which findings the change is allowed to absorb. This holds whether or not
   *this* skill was given `--fix` — that flag licenses the edits **this skill** makes after triage,
   never a blanket application upstream of it.
2. **A review sub-agent** (Agent tool): the repo's `.claude/agents/reviewer.md` if it defines one,
   otherwise `gantry-reviewer`. Give it the worktree path, the base branch, and `task.md`'s path —
   let it read the diff itself. Ask for correctness defects first, then reuse and simplification,
   each with a concrete failure or a concrete saving.
3. **Self-review**, only if neither is available, and **disclose it**. You reviewing your own
   change is the weakest source by a wide margin; the value of saying so is that the reader can
   weigh it correctly.

### 3. Verify every finding before it counts as one

**Check each finding against the file it names, before it is reported and before it is fixed.**
Reviewers, including good ones, report things that are not true — a defect in code the diff does
not contain, a call site that does not exist, a rule this repo does not hold.

This is a step rather than an aside because read-only mode makes it load-bearing. Without `--fix`
the report is the entire output of this phase, so an unverified finding is the whole of what the
caller receives, and it costs them more than it saves. The old placement — one clause telling you
to check findings "before acting" — only covered the case where something was going to be edited.

What does not survive is **dropped**, and counted in the tally rather than listed. A finding that
was checked and found untrue is not a finding; it is noise with a citation.

### 4. Triage what survived

Read `task.md`'s **Out of scope** section first — it is the boundary that makes this decision
something other than taste. Then sort each verified finding:

- **Address now** — a defect in the code this change introduced, or a small clear-cut cleanup
  inside the change's own footprint.
- **Defer** — real, but outside this task: a pre-existing bug the diff merely revealed, a
  refactor the finding would require, anything the contract excludes, anything large enough to
  need its own plan. **Never fix these.** Widening a change to absorb what review turned up is how
  a focused diff becomes an unreviewable one.
- **Drop** — pure style against a convention the repo does not hold. (Findings that were not true
  were already dropped in step 3; say how many fell out at each point, and do not list them all.)

The dividing line is scope, not difficulty. A one-line fix outside the contract still gets
deferred; a genuinely fiddly fix to code this change introduced still gets made.

Where the call is honestly ambiguous, ask — **AskUserQuestion**, one round, with the findings
described in terms of what each costs. With no human present, defer rather than expand: a deferred
finding is written down and recoverable, an unrequested refactor is neither.

### 5. Fix what you kept — only with `--fix`

**Without `--fix`, make no edit.** Report the address-now findings as what *would* be fixed, and
name `/gantry:review --fix` as the way to apply them. Skip to step 6; there is nothing to re-prove,
because nothing changed.

With `--fix`, make those fixes, then **re-run the gate** — a fix made after the gate went green is
unproven code:

```bash
bash "$GANTRY/lib/run_gates.sh"            # supervised
bash "$GANTRY/lib/run_gates.sh" --strict   # unattended
```

Same exit-code contract as `/gantry:implement`: `0` green · `1`+ red · `2` could not run · `3`
`NO-GATES` under `--strict`. Red here means your fix broke something — treat it exactly as
`implement` does, capped at 2 attempts unattended, stop and report supervised.

### 6. Hand over what you deferred

If anything was deferred, **invoke `gantry:handover`** and let it write `handover.md`. Pass it the
findings, why each is out of scope, and what the next person should do. Do not write the file
yourself — the handover skill owns its shape, and `/gantry:handover` typed by hand must produce the
same artifact this does.

**This happens with or without `--fix`.** A deferral is a fact about the review, not an edit to the
change, and the drivers journal `handover.md` as this phase's artifact. It is the one file a
read-only run still writes, and the reason ship re-detects after a bare `--review`.

Nothing deferred → no `handover.md`. An empty handover file is noise in the diff.

### 7. Record the status

Set `task.md` frontmatter to `status: reviewed` — **always, `--fix` or not.** The review happened;
that is what the status records. It is also the chain's memory: `lib/detect_stage.sh` reads it to
decide the phase, and is what moves this task on to `ship`. It is not the only reader —
`hooks/readiness-gate.sh` parses the same field with a copy of the same function, kept
byte-identical by a check in `scripts/verify.sh` — which is another reason not to make this write
conditional. Gating it on `--fix` would strand a
read-only review outside the state machine, leaving the detector to report `/gantry:review` as the
next command against a diff that was just reviewed.

If review found something that makes the change unsafe to ship at all, set `status: blocked`
instead, hand it over, and say so. Blocking here is cheap; blocking after the merge is not. When
`gantry:ship` invoked this phase through `--review` or `--review-fix`, a `blocked` verdict stops
the ship — no push, no PR.

## Report

Which source ran — named plainly, self-review disclosed as self-review. If source 1 did not run,
say what happened when you invoked it; "unavailable" with no cause is how a downgrade hides. The
**tier** that was passed, and if a tier was refused, which value and why.

**Two tallies, not one:** how many findings came back, and how many survived step 3's verification.
Then how many were addressed, deferred, and dropped. A run that reports "12 findings" when 5 were
untrue has told the reader something false about the diff.

Whether `--fix` was given. Without it, say plainly that nothing was edited and name what would have
been. With it, the gate's exit code. The `handover.md` path if one was written. End by naming the
next command: `/gantry:ship`.
