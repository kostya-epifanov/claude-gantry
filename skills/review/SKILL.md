---
name: review
description: Get an independent review of the diff, verify every finding against the repo, then triage what survives against the task contract — handing what's out of scope to /gantry:handover rather than quietly widening the change. Read-only unless you pass --fix, which applies the findings triage keeps. Pass --tier medium|high|xhigh|max to set the depth (default high). Use when the user types "/gantry:review", or asks to review the diff, check the changes, or get a second opinion before shipping.
argument-hint: [--tier <medium|high|xhigh|max>] [--fix] [--headless]
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Skill, Agent, AskUserQuestion, SendMessage
---

# gantry:review

Review the change, then do something about it. The reviewing half is worth little without the
triage half: a list of findings nobody acted on is not a review, it is a receipt.

**Read-only by default.** With no `--fix`, this skill makes **no change to the code under review**.
It still writes gantry's own artifacts — `task.md`'s status, always; `review.md`, the findings that
are in scope to fix, always; and `handover.md` when something is deferred — because those are the
chain's bookkeeping rather than the change. `--fix` is what licenses it to edit the code.

**`--tier <medium|high|xhigh|max>`**, default `high`. The depth of the `/code-review` run in step 2.
See that step for what the values mean and which are refused.

**`--headless`**: this run is a child session nobody is watching — the drivers launch it through
`lib/run_phase_headless.sh`, and `gantry:ship --review` does too. The one thing it changes is
step 4: a finding whose triage is honestly ambiguous is **deferred** rather than asked about,
whatever `mode:` says and whether or not `task.md` names a `lead:`. A print-mode child exits when it
ends its turn, so it cannot wait for an answer; a deferred finding is written down and recoverable.

**`--fix` is stage-aware.** When `review.md` already lists findings from a review that finished,
`--fix` **applies them** and does not review again — see step 1. That split is what lets a driver
run the review in one child session and the fix in another.

## Steps

### 1. Detect the stage and get the diff

`$GANTRY` is this skill's plugin root — resolve it from this file's own location rather than
hardcoding a path.

```bash
bash "$GANTRY/lib/detect_stage.sh"
```

- `PHASE:not-a-repo` → stop.
- `STATUS:implementing` → **stop, in every mode.** The implementation has not finished: the gate
  has not gone green on it, and reviewing a tree `implement` has not proved is reviewing the wrong
  thing. Name `/gantry:implement`.
- `TASK:absent` → warn: with no contract there is nothing to check the change *against*, so the
  review is against general quality only. Continue; say so in the report.
- `TASK:inherited` → **treat it as `absent`, not as `present`.** The `task.md` on disk is the
  previous, merged task's contract — a freshly branched worktree is born holding it — so its
  acceptance criteria and *Out of scope* describe a different change. Reviewing this diff against
  them triages findings by the wrong boundary. Warn as above and say which it was.
- `STATUS:planned` / `grilled` → nothing has been implemented yet. If the tree is clean there is
  nothing to review — say so and name `NEXT`. If it is dirty, someone worked by hand; review that,
  and say that is what happened.

**Then read `REVIEW:`.** It is what decides what `--fix` means on this run:

- `--fix` + `REVIEW:pending` + `STATUS:reviewed` → **apply mode.** A review already ran, finished,
  and recorded what is in scope to fix. Skip steps 2–4 and 6 and go to step 5, which starts by
  checking that `review.md` describes *this* diff.
- `--fix` + `REVIEW:pending` + any other status → **stop.** A findings file without a `reviewed`
  status means the review that wrote it did not finish (it died after writing the file and before
  writing the status). Name `/gantry:review` so it runs again from the start.
- `--fix` + `REVIEW:applied` or `REVIEW:clean` → nothing is pending. Say so — the file is either
  already applied or records that there was nothing to apply — and name `/gantry:ship`. Stop.
- `--fix` + `REVIEW:absent` → the ordinary path: review, then fix, in this run.
- no `--fix`, any `REVIEW:` value → review. An existing `review.md` is a previous review's and is
  **overwritten** in step 4b; this run supersedes it.

Then get the diff. **The tree is usually uncommitted at this point** — `gantry:ship` commits, and
it has not run yet — so a three-dot range against the base is empty and will make an unreviewed
change look clean:

```bash
git diff <BASE>            # committed + working-tree changes vs the base
git status --short         # untracked files the diff above cannot show
```

`<BASE>` is the branch this one will merge into, resolved the way `gantry:ship` resolves it:
`develop` when it exists, else the branch `origin/HEAD` points at, else `main` or `master` —
preferring the `origin/` ref whenever one exists. Say which it was; `review.md` records it.

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
   and the headless launcher forward a tier here unvalidated rather than keeping a second copy of
   the list that could drift out of step with this one.

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
described in terms of what each costs. If `task.md`'s frontmatter names a `lead:`, put this
question to the lead instead, as a `fork`, following `$GANTRY/skills/auto/references/lead.md`. With
no human present, defer rather than expand: a deferred finding is written down and recoverable, an
unrequested refactor is neither.

**Under `--headless`, defer instead of asking — always**, whatever `mode:` says and even when a
`lead:` is named. The child cannot wait for a reply. Count how many findings went that way; the
report says so, and the driver shows them at its checkpoint from `handover.md`.

### 4b. Record the findings

**Always, on the review path** (not in apply mode). Write `review.md` at the worktree root — with
the Write tool, overwriting whatever is there, because a file left by an earlier review describes
a diff that has since moved. Keep it out of git first; the launcher has already asserted this for
a headless child, and a hand-typed run asserts it now:

```bash
bash "$GANTRY/lib/ensure_excluded.sh" /task.md /plan.md /handover.md /review.md
bash "$GANTRY/lib/diff_fingerprint.sh" <BASE>
```

The second command prints the one token that ties this file to this diff. The file:

```
# Review
branch: <branch>
base: <BASE>
diff: <the token diff_fingerprint.sh printed>
source: code-review | gantry-reviewer | self-review
tier: <tier>
tallies: returned=<n> verified=<n> address-now=<n> deferred=<n> dropped=<n>

## Address now
- `<path>:<line>` — <what is wrong>. Failure: <inputs → wrong result>.
```

One bullet per address-now finding, each with the file, the line, what is wrong and the concrete
failure — enough for a fix step in another session to act on without re-reviewing. **No
address-now findings → the section still exists and reads `None.`** on its first line, so the fix
step can tell "reviewed, nothing to apply" from "never reviewed"; `lib/detect_stage.sh` reads that
line as `REVIEW:clean`.

No `session:` line, deliberately: a child cannot read its own session id, and the launcher already
reports it from the child's JSON result.

### 5. Fix what you kept — only with `--fix`

**Without `--fix`, make no edit.** Report the address-now findings as what *would* be fixed, and
name `/gantry:review --fix` as the way to apply them. Skip to step 6; there is nothing to re-prove,
because nothing changed.

With `--fix`, first — **in apply mode only** — check that `review.md` describes this tree:

```bash
bash "$GANTRY/lib/diff_fingerprint.sh" <base from review.md's base: line>
```

Its `branch:` must equal the current branch and its `diff:` must equal the token just printed.
**Otherwise stop**: say the file describes a different diff (or a different branch) and name
`/gantry:review` to review the tree as it is now. Applying stale findings to a moved tree is worse
than applying none.

Then make the fixes `review.md` lists — on the ordinary path, the ones step 4 just kept. Read each
file a finding names before editing it; a listed finding that no longer holds is skipped and said
so, never invented into the code. Then **re-run the gate** — a fix made after the gate went green
is unproven code:

```bash
bash "$GANTRY/lib/run_gates.sh"            # supervised
bash "$GANTRY/lib/run_gates.sh" --strict   # unattended
```

Same exit-code contract as `/gantry:implement`: `0` green · `1`+ red · `2` could not run · `3`
`NO-GATES` under `--strict`. Red here means your fix broke something — treat it exactly as
`implement` does, capped at 2 attempts unattended, stop supervised.

**Then append one line to `review.md`, last, with the gate's final exit code:**

```
applied: <ISO-8601 UTC date> gate=<exit>
```

That line is how the detector reports `REVIEW:applied` and how the headless launcher reads
`GATE_EXIT:` back for the driver, so it is written on every `--fix` run that applied anything —
including a run whose gate ended red. If the gate ended red after the attempts the mode allows,
also set `task.md` to `status: blocked` and stop: a tree whose fixes broke the checks is unsafe to
ship, and the drivers read that status.

### 6. Hand over what you deferred

If anything was deferred, **invoke `gantry:handover`** and let it write `handover.md`. Pass it the
findings, why each is out of scope, and what the next person should do. Do not write the file
yourself — the handover skill owns its shape, and `/gantry:handover` typed by hand must produce the
same artifact this does.

**This happens with or without `--fix`.** A deferral is a fact about the review, not an edit to the
change, and the drivers journal `handover.md` as this phase's artifact. It is the one file a
read-only run still writes — and since 0.5.0 it is excluded rather than committed, so writing it
moves nothing `gantry:ship` has to re-detect. It reaches the reviewer through the pull request
body, which ship composes.

Nothing deferred → no `handover.md`. An empty handover file is noise in that body.

### 7. Record the status

Set `task.md` frontmatter to `status: reviewed` — **always, `--fix` or not.** The review happened;
that is what the status records. It is also the chain's memory: `lib/detect_stage.sh` reads it to
decide the phase, and is what moves this task on to `ship` — or, while `review.md` still lists
findings, keeps it at the fix step. It is not the only reader —
`hooks/readiness-gate.sh` parses the same field with a copy of the same function, kept
byte-identical by a check in `scripts/verify.sh` — which is another reason not to make this write
conditional. Gating it on `--fix` would strand a
read-only review outside the state machine, leaving the detector to report `/gantry:review` as the
next command against a diff that was just reviewed. In apply mode the status is already `reviewed`
and stays so, unless step 5 set `blocked`.

If review found something that makes the change unsafe to ship at all, set `status: blocked`
instead, hand it over, and say so. Blocking here is cheap; blocking after the merge is not. When
`gantry:ship` invoked this phase through `--review` or `--review-fix`, a `blocked` verdict stops
the ship — no push, no PR.

## Report

Which source ran — named plainly, self-review disclosed as self-review. If source 1 did not run,
say what happened when you invoked it; "unavailable" with no cause is how a downgrade hides. The
**tier** that was passed, and if a tier was refused, which value and why.

**Two tallies, not one:** how many findings came back, and how many survived step 3's verification.
Then how many were addressed, deferred, and dropped — and under `--headless`, how many were
deferred because they would otherwise have been asked about. A run that reports "12 findings" when
5 were untrue has told the reader something false about the diff.

Whether `--fix` was given, and whether this was apply mode. Without `--fix`, say plainly that
nothing was edited and name what would have been. With it, the gate's exit code. The `review.md`
path and the `REVIEW:` value the detector now reports; the `handover.md` path if one was written.
End by naming the next command: `/gantry:review --fix` while `REVIEW:pending`, else `/gantry:ship`.
