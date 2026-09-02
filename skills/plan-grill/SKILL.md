---
name: plan-grill
description: Attack the plan before the code is written — a fresh critic sub-agent reads task.md and plan.md cold and hunts for the assumptions, unfalsifiable criteria, and missing steps that would surface halfway through implementing. Use when the user types "/gantry:plan-grill", or asks to review, critique, stress-test, or poke holes in a plan.
argument-hint: ""
allowed-tools: Bash, Read, Edit, Skill, Agent, AskUserQuestion
---

# gantry:plan-grill

Take the plan apart before it costs anything to be wrong. This phase sits between `/gantry:plan`
and `/gantry:implement` for one reason: a defect found in `plan.md` costs a paragraph, and the same
defect found in `implement` costs the implementation.

## Always delegate. That is the whole skill.

**Dispatch a fresh sub-agent for the critique, every time, in every mode — including when a human
typed `/gantry:plan-grill` directly.** A context that just wrote the plan cannot grill it: it already
believes the assumptions, has already dismissed the alternatives, and will reliably rate its own
reasoning higher than a stranger would. Self-critique from the authoring context is theatre.

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

- **`PLAN:absent`** → there is nothing to grill. Say so and point at `/gantry:plan`. Do not invent
  a plan in order to critique it.
- **`PLAN:present`** → continue, whatever `STATUS` says. Grilling an already-grilled plan is a
  legitimate second pass, and grilling a plan mid-implementation is legitimate too — say which
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

Where a finding turns on a decision only the user can make, ask — **AskUserQuestion**, one round.

With no human present, the answer depends on what kind of finding it is:

- **A judgement call inside the plan** — how thorough a step should be, which of two equivalent
  orderings to take — take the conservative reading and record it as an assumption.
- **A genuine design fork**, where two answers would send the work in materially different
  directions: **do not take a reading at all.** Add it to `task.md`'s **Open questions** as an
  unchecked item, exactly as `gantry:plan` would have. A fork found here is the phase succeeding —
  it is cheaper now than at review — and absorbing it into an assumption is how it reaches the code
  anyway.

### 4. Revise `plan.md`

Edit the plan in place. Then append a short section recording the pass:

```markdown
## Grilled

- <finding> → <what changed, or why it was left>
```

Keep it to the findings that mattered. The point of the record is that the next reader can see what
was already considered and not re-raise it — including you, on a second pass.

### 5. Record the status

Run the detector again and read its **`FORKS:`** line before writing anything. This phase can
*open* a fork that `gantry:plan` never had — step 3 says to record one rather than absorb it — so
the check that ran at the end of planning is not the check that matters here.

- **`FORKS:none`** → set `task.md` frontmatter to `status: grilled`.
- **`FORKS:open`** → **leave the status alone** and report the fork. `grilled` means the plan is
  ready to implement, and it is not: `/gantry:implement` refuses on an open fork when a driver
  dispatched it, so marking it `grilled` would only move the stop somewhere less informative.
- **`FORKS:unknown`** → warn that the section is missing, and continue.

If the critique concluded the task itself is wrong — the goal is unachievable as stated, or far
larger than the contract admits — do not quietly shrink it. Set `status: blocked`, say so, and
invoke `/gantry:handover` to write up what was found. That is a legitimate and useful outcome of
this phase.

## Report

Which critic ran, how many findings came back at each severity, what changed in the plan, and what
was consciously left. Be explicit when nothing needed changing. Say whether the critique **opened a
fork** — that is the one finding that stops the chain rather than revising it.

End by naming the next command: `/gantry:implement` on `FORKS:none`, or the open fork on
`FORKS:open`.
