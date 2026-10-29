---
name: plan-critique
description: Attack the plan before the code is written — a fresh critic sub-agent reads task.md and plan.md cold and hunts the assumptions, unfalsifiable criteria, and missing steps that would surface halfway through implementing. Headless; it asks nothing. Use when the user types "/gantry:plan-critique", or asks to critique or stress-test a plan.
argument-hint: ""
allowed-tools: Bash, Read, Write, Edit, Skill, Agent
---

# gantry:plan-critique

Take the plan apart before it costs anything to be wrong. A defect found in `plan.md` costs a
paragraph; the same defect found in `implement` costs the implementation.

This phase is **headless**. It asks nothing, on any path, so it is available in every mode —
including `gantry:auto-unattended`, where there is nobody to ask. Converging on the approach with a
human is the next phase's job, `/gantry:grill`. The split is along mechanism versus interface: the
cold read needs no human and must not have one, while agreeing the approach needs nothing else.

## Always delegate. That is the whole skill.

**Dispatch a fresh sub-agent for the critique, every time, in every mode — including when a human
typed `/gantry:plan-critique` directly.** A context that just wrote the plan cannot critique it: it
already believes the assumptions, has already dismissed the alternatives, and will reliably rate
its own reasoning higher than a stranger would. Self-critique from the authoring context is
theatre.

So the critic gets the artifacts and nothing else — no conversation, no rationale you remember, no
defence of a choice. It reads `task.md` and `plan.md` cold, exactly as the next engineer would.

If you find yourself about to critique the plan inline because it "looks quick", that is the
failure mode this paragraph exists to stop. Delegate anyway.

## Steps

### 1. Detect the stage

`$GANTRY` is this skill's plugin root — resolve it from this file's own location rather than
hardcoding a path.

```bash
bash "$GANTRY/lib/detect_stage.sh"
```

- **`PLAN:absent`** → there is nothing to critique. Say so and point at `/gantry:plan`. Do not
  invent a plan in order to critique it.
- **`PLAN:present`** → continue, whatever `STATUS` says. Critiquing an already-critiqued plan is a
  legitimate second pass, and critiquing a plan mid-implementation is legitimate too — say which
  situation you are in.
- `PHASE:not-a-repo` → stop.

### 2. Dispatch the critic

Use the **Agent** tool: the repo's `.claude/agents/critic.md` if it defines one, otherwise
`gantry-critic`. Give it the worktree path and the two file paths — **paths, not contents**, so it
reads them itself rather than inheriting your reading of them.

Ask it for findings against these lines of attack:

- **Unstated assumptions.** What must be true for this plan to work that nobody has checked?
- **Unfalsifiable acceptance criteria.** Which of them cannot be shown false? Those are wishes.
- **Steps that will fail.** Which step assumes an interface, a file, or a behaviour that is not
  actually there? This is the one worth reading code to answer.
- **Missing steps.** Migration, backfill, error paths, the callers of the thing being changed,
  cleanup of what is being replaced.
- **Scope.** Anything in the plan that the task's *Out of scope* section excludes — and anything in
  the acceptance criteria that the plan never addresses.
- **Test strategy.** What breaks without a test noticing?

Require each finding to carry a **severity** (blocking / worth fixing / noted) and a **concrete
consequence** — what actually goes wrong, not that something is "unclear". A finding with no
failure attached is a style note; ask it to drop those.

### 3. Triage the findings

Findings are input, not verdicts. Read each one against the repo and decide:

- **Blocking** → the plan is wrong and must change before implementing.
- **Worth fixing** → fold it in now; it is cheap here.
- **Noted** → record it in `plan.md` and move on. A critic that found nothing worth acting on is a
  useful result, not a failure — say so rather than manufacturing changes to look busy.

**This phase never asks, so a finding that turns on someone else's decision is recorded, not
resolved.** Which of the two it is decides what you do with it:

- **A judgement call inside the plan** — how thorough a step should be, which of two equivalent
  orderings to take — take the conservative reading and record it in `plan.md` as an assumption.
- **A genuine design fork**, where two answers would send the work in materially different
  directions: **do not take a reading at all.** Add it to `task.md`'s **Open questions** as an
  unchecked item, exactly as `gantry:plan` would have, and leave it open. A fork found here is the
  phase succeeding — it is cheaper now than at review — and absorbing it into an assumption is how
  it reaches the code anyway.

Every open fork then belongs to `/gantry:grill`, which is where they are put to a human and closed.

### 4. Revise `plan.md`

Edit the plan in place. Then append a short section recording the pass:

```markdown
## Critique

- <finding> → <what changed, or why it was left>
```

Keep it to the findings that mattered. The point of the record is that the next reader can see what
was already considered and not re-raise it — including you, on a second pass, and including the
grill dialogue that reads this file to decide what is worth a question.

### 5. Record the status

Run the detector again and read its **`FORKS:`** line before writing anything. This phase can
*open* a fork that `gantry:plan` never had — step 3 says to record one rather than absorb it — so
the check that ran at the end of planning is not the check that matters here.

**Set `status: critiqued` whenever the critique ran — forks open or not.** The status records one
fact, that a critic read this plan, and that fact is true either way. Forks are `grill`'s business,
and `grill` routes on `critiqued`.

Do **not** "leave the status alone" on an open fork. `plan` now marks `planned` with forks open —
that is its normal exit — so leaving the status alone after a critique would leave `planned` on
disk, which says nothing read the plan when something just did. Three things then break: `grill`
re-enters at `planned` and dispatches a **second** full critique, appending a duplicate
`## Critique`; `gantry:auto`'s grill stage enumerates `grilled`/`critiqued`/`blocked` and has no
branch for `planned`, so it falls through to `/gantry:implement`'s hard refusal with nothing
explaining why; and the fork — the case this whole phase exists to surface — is the one case that
misroutes.

- **`FORKS:open`** → set `status: critiqued` **and report the fork**, by name. The status is not the
  place that stops the chain; `grill` and `/gantry:implement` both read the forks directly.
- **`FORKS:unknown`** → warn that the section is missing, set the status, and continue.

`critiqued` says exactly one thing: a critic read this plan. It does **not** say a human agreed to
it — that is `grilled`, and only `/gantry:grill` writes it. Keeping those two apart is the whole
reason this phase has its own status.

If the critique concluded the task itself is wrong — the goal is unachievable as stated, or far
larger than the contract admits — do not quietly shrink it. Set `status: blocked`, say so, and
invoke `/gantry:handover` to write up what was found. That is a legitimate and useful outcome of
this phase.

## Report

Which critic ran, how many findings came back at each severity, what changed in the plan, and what
was consciously left. Be explicit when nothing needed changing. Say whether the critique **opened a
fork** — that is the finding a human has to settle rather than one you revised around.

Assert that the critique came from a dispatched agent. A phase whose one guarantee is a cold read
should say, every time, that it did not read its own homework.

End by naming the next command: `/gantry:grill`, which puts any open fork to a human and converges
on the approach. Under `gantry:auto-unattended` there is no grill — the driver takes `critiqued`
straight to `/gantry:implement`, and an open fork stops the run instead.
