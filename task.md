---
id: 2026-08-29-ship-review-and-fork-precondition
title: Fold review into ship, and make settled forks a precondition of leaving plan
project: claude-gantry
branch: feat/ship-review-and-fork-precondition
mode: unattended          # semi-auto | auto | unattended — which mode is driving
status: shipped           # planning | planned | grilled | implementing | implemented |
                          # reviewed | shipped | blocked. The readiness hook arms on
                          # exactly `implementing` and ignores every other value.
---

## Context & goal

Two independent gaps in the pipeline, tracked upstream as items 1.3 and 2.5.

**1.3 — review is optional in practice.** `gantry:ship` today goes commit → push → PR with no
review in between. Review only happens when a driver runs the `review` phase, or when someone
types `/gantry:review` by hand. Anyone who reaches for `/gantry:ship` directly — which is the
common case for a small change — opens a PR that nothing has read. Ship is the last place a
change is still cheap to fix, so a review stage belongs there, between the commit and the PR.

**2.5 — a design fork survives all the way into the code.** `task.md` carries an *Open questions*
section for the forks the implementer must not resolve alone, but nothing enforces that it is
empty before implementation starts. Today it is a habit: supervised runs may or may not surface
the forks, and unattended runs are explicitly told to pick "the most conservative reading" and
carry on. Both fail the same way — a decision nobody made turns into an hour of work in the wrong
direction, discovered at review. The fix is to move the fork from hour three to minute two: an
open fork is a precondition of leaving the plan stage, put to the user when there is one and a
hard stop when there is not. An implementer is never dispatched against an open fork.

The two changes share nothing but the file set. They are shipped together because they are one
coherent pass over the driver and ship skills.

## Acceptance criteria

### 1.3 — review folded into ship

- [ ] `skills/ship/SKILL.md` has a numbered stage between the commit stage and the push stage
      whose body invokes `/code-review` with `--fix` and a named effort level, scoped to the
      branch diff.
- [ ] That stage's body contains no enumeration of finding categories and no triage rule —
      `grep -c` for `Address now`, `Defer`, `Drop` in `skills/ship/SKILL.md` returns 0. It names
      the command; `skills/review` keeps the procedure.
- [ ] The stage is skipped when `--no-pr` is passed, and when `--reviewed` is passed, and ship
      says which.
- [ ] `--reviewed` appears in ship's `argument-hint`, in the `gantry:ship` invocation in both
      drivers, and in orchestration's pass-through list.
- [ ] `task.md`'s `status:` is **not** consulted by the guard, and ship's prose says why.
- [ ] The gate is re-run only when `--fix` changed the tree; on a non-zero exit ship stops before
      the push, and the review's own verdict never blocks anything.
- [ ] Ship's report states whether the review ran and how many files `--fix` touched. It does not
      report a findings tally, which nothing in this repo establishes is available.
- [ ] `/code-review` being unavailable is a documented non-fatal outcome, reported with its cause.
- [ ] The renumbered stage headings run 1–6 with no gaps, and no prose in the file refers to a
      stage by a number it no longer has.

### 2.5 — settled forks as a plan-stage precondition

- [ ] `lib/detect_stage.sh` reports `FORKS:` with all four of `absent`, `unknown`, `open`, `none`,
      and its header comment documents the heading match, the section terminator, fence skipping,
      nesting, and how a bare bullet is read.
- [ ] `scripts/verify.sh` asserts the `FORKS:` value against fixtures covering, at minimum: an
      unchecked box in *Acceptance criteria* with a settled *Open questions* (must be `none`), an
      unchecked box inside a fenced block (must be `none`), a bare bullet (must be `open`), and a
      `task.md` with no such heading (must be `unknown`).
- [ ] A `task.md` freshly copied from `skills/plan/templates/task.md` reports `FORKS:none`.
- [ ] `skills/plan/SKILL.md` sets `status: planned` only on `FORKS:none`, and tells the reader to
      mark a settled fork as a checked item rather than delete it.
- [ ] `skills/grill/SKILL.md` sets `status: grilled` only on `FORKS:none`, and routes a critique
      finding that is a genuine fork into *Open questions*.
- [ ] `skills/implement/SKILL.md` refuses on `FORKS:open` when `mode:` is `auto` or `unattended`,
      and warns without refusing otherwise.
- [ ] `skills/auto/SKILL.md` runs an `AskUserQuestion` round on `FORKS:open` at two points: after
      plan and after grill.
- [ ] `skills/auto-unattended/SKILL.md` journals an `escalation` event, sets `status: blocked`, and
      stops on `FORKS:open` at those same two points. Its open-fork paragraphs contain no
      conditional continuation — `grep -niE 'otherwise|unless|if the fork'` within them returns
      nothing.
- [ ] Both drivers' stage sections and the mode table in
      `skills/auto/references/orchestration.md` describe the new behaviour. (Neither driver
      contains a markdown table; none is added.)
- [ ] `skills/auto-unattended/references/journal.md` documents the `escalation` shape with a worked
      example, and no longer says nothing emits it.
- [ ] No file still *instructs* a run with no human present to resolve a design fork by taking the
      conservative reading. Read every hit of `grep -rn conservative skills/`: each must either
      forbid the practice or scope it to a judgement call inside a plan, never to a fork.

### Both

- [ ] Every statement this change falsifies is corrected: the "two hard refusals, and only two"
      and "`ship` does not re-check the gate" claims in `docs/SKILLS.md`, the same refusal claim
      inline in `skills/implement/SKILL.md`, and "the gate is never delegated" in
      `skills/auto-unattended/references/delegation.md`.
- [ ] `bash scripts/verify.sh` exits 0.

## How to verify

```yaml
verification:
  automated:
    lint: true              # bash -n + shellcheck, via scripts/verify.sh
    tests: true             # scripts/verify.sh is the whole suite CI runs
  human_only:
    - "Read skills/ship/SKILL.md end to end: the review stage reads as one step in ship's
       existing numbered flow, not as a transplanted copy of skills/review."
    - "Read skills/auto-unattended/SKILL.md: the open-fork path is a stop with no continuation
       branch. There is no wording under which the run proceeds to implement."
```

```bash
bash scripts/verify.sh                      # the gate; must exit 0
grep -n "code-review" skills/ship/SKILL.md  # the new stage invokes, does not reimplement
```

## Out of scope

- The consuming repo that tracks these items. Nothing outside this repository is touched.
- The gate contract. `lib/run_gates.sh`'s exit-code semantics (`0` green, `1+` red, `2` could not
  run, `3` NO-GATES under `--strict`) are unchanged, and no skill gains the ability to overrule
  them. The review stage added by 1.3 is advice; the exit code stays law.
- `hooks/readiness-gate.sh`, and `lib/detect_stage.sh`'s existing behaviour. The hook's arming
  condition is untouched, and so are `PHASE`, `NEXT`, and `frontmatter_status()` — the last of
  which `scripts/verify.sh` requires to stay byte-identical to the hook's copy.

  What **is** in scope, stated plainly rather than as a footnote: the detector gains one new
  reported line, and that line becomes the chain's third hard refusal (in `implement`, on a
  dispatch). That is a real behaviour change, not a reporting change, and it is deliberate — a
  precondition only prose enforces is the habit this task exists to replace. It is also why
  several shipped statements about "two hard refusals" have to be corrected rather than left
  standing.
- Teaching `/gantry:review` anything new. 1.3 moves a review to a new place; it does not change
  what a review is. It gains one cross-referencing sentence and no behaviour.
- Any new script, and any new test harness. This repo has none, and adding one to land a change
  that is almost entirely skill prose would be a larger change than the one requested.

## Affected areas

Mapped by a `gantry-explorer` dispatch over everything outside the skill bodies being edited.

**Item 1.3 — ship's stages are described in six places.** `skills/ship/SKILL.md` is the flow
itself (frontmatter `argument-hint` and `description`, the flag paragraphs, and stage numbers
cross-referenced from at least three paragraphs outside the headings). `skills/ship/scripts/detect_state.sh`
restates the path in its header comment. `README.md` carries it twice — in *The chain* and in the
skill table's flag list. `docs/SKILLS.md` has both the three-modes table and a `gantry:ship`
entry repeating the `argument-hint`. `docs/ARCHITECTURE.md` has two diagrams: *who invokes whom*,
and a ship state-machine whose `STAGE` list enumerates every entry point. `skills/sync/SKILL.md`
names `/gantry:ship` in passing and needs nothing.

**Item 1.3 — `/code-review`'s invocation shape** is set by `skills/review/SKILL.md` step 2, which
forbids both `ultra` and `--fix` and requires a named effort level. `docs/SKILLS.md` and
`docs/ARCHITECTURE.md` both describe the three review tiers, as does the delegation table in
`skills/auto/references/orchestration.md`.

**Item 2.5 — the fork surface.** `skills/plan/SKILL.md` holds the conservative-reading rule in two
places (*Ask, don't assume*, and the step that records status). The same rule is restated in
`skills/auto-unattended/SKILL.md`'s plan stage and in orchestration's *Preconditions for
unattended*. `skills/grill/SKILL.md` carries its own conservative-reading sentence for critique
findings — a fork grill raises must land in *Open questions* too, or the precondition has a hole.
The section's own definition lives in `skills/plan/templates/task.md` and `examples/task.md`,
which `scripts/verify.sh` requires to be byte-identical. `lib/detect_stage.sh` is where a
machine-checkable answer has to come from; its header comment documents every output line.

**Risks the map surfaced.** `scripts/verify.sh` rejects any markdown carrying a line-number
citation, requires every relative markdown link to resolve, and diffs the template against the
example — so the parity edit must be a copy, not two hand-edits. Renumbering ship's stages is the
single highest-risk edit, because the numbers are referenced from prose the headings do not
contain.

## Open questions

Settled. Every fork this task raised was closed by reading the repository rather than by choosing,
so no decision was left for the implementer:

- [x] **How ship learns a review already ran** — the repo's existing convention is that handoff
      between phases is via disk plus explicit flags, never conversation. Ship takes a `--reviewed`
      flag from the drivers *and* honours the `status:` already on disk.
- [x] **What ship does when `/code-review` is unavailable** — this repo's rule is that the gate is
      the only blocker. A missing reviewer is reported, not fatal.
- [x] **Whether the review stage is opt-in** — the task statement settles it: a stage in the flow,
      skipped only on `--no-pr` or an already-reviewed chain.
- [x] **Whether to rename the section to match the upstream wording** — no. Gantry's heading stays
      `## Open questions`; the upstream phrase becomes the section's one-line description in the
      template, so the intent is captured without churning a heading other files point at.
