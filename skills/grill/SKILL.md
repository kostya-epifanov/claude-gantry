---
name: grill
description: Converge on the right approach by talking it through — explain the problem, then ask in rounds where every option is priced by what it costs, and fold the decisions into task.md. Chains the cold critique first if it has not run. Use when the user types "/gantry:grill", or asks to agree or think through an approach before implementing.
argument-hint: "[--rounds N] [--lead <session>]"
allowed-tools: Bash, Read, Write, Edit, Skill, Agent, AskUserQuestion, SendMessage
---

# gantry:grill

Settle **whether this is the way to get what the task came for** — the question with the most
leverage at plan time, and the one question a human can answer and a critic cannot.

A critic attacks a plan from inside the plan's own approach. Its lines of attack — steps that will
fail, missing migration, unfalsifiable criteria — all presuppose the approach is the right one. So
the cold read happens in `/gantry:plan-critique`, and this phase does the thing a cold read
structurally cannot: it asks the person who knows what *efficient* means in their context.

What it replaces is a count and a yes/no. The old phase reported "4 findings, 2 folded in, 1 noted"
and asked *"Proceed with this plan?"* — the cheapest possible form of input, on a plan already
revised, with the reasoning compressed away exactly where it was worth the most.

**It never critiques inline.** The critique always comes from a dispatched agent, because a context
that converses about the plan is not the context that can attack it. This phase asserts that in its
report, every time.

> **A note on the name.** Before 0.4.x, `/gantry:grill` *was* the cold critique, and it was renamed
> to `/gantry:plan-grill` to say so. As of 0.7.0 the name is back and means something different:
> the critique is `/gantry:plan-critique`, and `grill` is this conversation. If you typed it from
> muscle memory expecting a silent critic, that is what changed.

## Steps

### 1. Chain the critique if it has not run

`$GANTRY` is this skill's plugin root — resolve it from this file's own location rather than
hardcoding a path.

```bash
bash "$GANTRY/lib/detect_stage.sh"
```

- **`PLAN:absent`** → there is nothing to grill. Say so and point at `/gantry:plan`.
- **`STATUS:planning`** → the plan is still being drafted. Say so and point at `/gantry:plan`;
  grilling a draft wastes the one asking moment on prose that is about to change.
- **`STATUS:planned`** → **invoke `/gantry:plan-critique` first**, then continue here. Typing
  `/gantry:grill` by hand should do the whole thing rather than failing on a missing precondition.
- **`STATUS:critiqued`** → go straight to the dialogue, and say the critique already ran so nobody
  wonders whether it was skipped.
- `PHASE:not-a-repo` → stop.

Read `plan.md`'s `## Critique` section from disk either way. It is what tells you which findings are
live, and it is the only record of what the critic said.

### 2. Explain the problem, then ask

Before the first question, put **one screen** in the session:

- what the task is for — the problem, not the instruction;
- the approach `plan.md` takes, in a sentence or two;
- which of the critique's findings actually bear on that approach, and which are housekeeping;
- what the efficient path looks like from here, and why.

**The brief explains the problem, not the plan's table of contents.** A reader who already has the
plan does not need it summarised; they need to know what decision is in front of them and what it
turns on.

Keep it honest rather than persuasive. A brief written to sell the plan is worse than the old
checkpoint, because it spends the human's attention and returns a rubber stamp.

### 3. Rounds

Up to `--rounds N`. **Default 3 with a human present, 1 when a lead is answering** — a lead
sequencing several lanes pays a message round-trip per round through `lib/lead_reply.sh`'s re-ask
cap, so the conversation that is cheap in a terminal is expensive by message. That lead default is a
judgement rather than a measurement; one real lead-driven run should confirm or move it.

**Read the lead from disk, not from a flag.** If `task.md`'s frontmatter names a `lead:`, this run
has a lead — whoever invoked the phase and however it was typed. `gantry:auto` also passes
`--lead <session>` when it has one, and that is honoured, but the frontmatter is the authority: a
hand-typed or resumed `/gantry:grill` in a lead-driven lane has no flag, and treating it as
human-present would call `AskUserQuestion` into a lane nobody is watching and hang the run.

Each round is **one `AskUserQuestion` call** — up to 4 questions, 2–4 options each. With a lead,
every question goes to the lead instead, following
`$GANTRY/skills/auto/references/lead.md`: the rounds are `fork` questions, the terminal question of
step 5 is a `checkpoint`.

Four rules govern what a round may contain:

- **Every question leads with a recommendation.** You have read the plan and the critique; making
  the user infer your reading is not neutrality, it is withholding.
- **Every option is described by what it costs**, not by what it is — and **the recommended
  option's own cost is named too.** A round where only the alternatives have drawbacks is a sales
  pitch with extra steps.
- **A round only happens if it would change the plan.** Ask because an answer just received
  invalidated a step, or because the critique holds a fork the first round did not cover. Never ask
  to confirm something already settled.
- **Proportionality.** Nothing blocking from the critic, no open forks, a narrow diff → **one
  round, one question.** A three-round interrogation about a one-file change is how a good phase
  gets switched off, and a phase nobody runs guarantees nothing.

**The escape is always open.** A reply meaning *"go with your recommendation"* ends the dialogue
immediately — do not ask the remaining questions. Decide every outstanding fork by your own
recommendation and record each one in `task.md` as **decided by recommendation, unconfirmed**, so
the next reader can tell a decision somebody made from one nobody did.

### 4. Converge, then write to disk

Every phase reads disk, never the conversation, so a decision that exists only in this session
exists nowhere:

- **Each settled fork checked off in place** — `- [x] <fork> — <decision, and what settled it>`.
  Never delete one: a deleted entry is indistinguishable from one that was never raised.
- **Approach changes folded into `plan.md`.** If the conversation changed the approach, the plan has
  to say so before an implementer reads it.
- **A `## Decisions` section in `task.md`**, one entry per question: the question, the options
  considered, what was chosen, and **why**. This is the section `gantry:ship` quotes into the pull
  request body, so it is how the reasoning reaches a reviewer at all. The old `## Grilled` log lived
  in `plan.md`, which ship does not quote, which is why it never did.

Take care that nothing written into `## Decisions` reads as an open fork — `lib/detect_stage.sh`
parses list items, and a bare bullet or an unchecked box counts as open wherever it sits.

### 5. The last round is the approval

On convergence, ask the terminal question — *proceed with this approach?* — and then record the
outcome. **That question is the approval**; `gantry:auto` has no separate plan checkpoint, because
a yes at the end of a conversation is worth more than a yes in front of a wall of text.

This is also the last cheap moment to catch **a wrong branch name**: nothing has been edited yet,
so the worktree can be recreated for the cost of one command. After `implement` there is a diff to
move. Mention it if the branch looks wrong.

Then:

- **Converged, every fork closed** → set `task.md` to `status: grilled`.
- **`FORKS:open` still** → the phase did not finish. **Leave `critiqued`**, report the fork, and do
  **not** mark `grilled`. Closing every open fork is this phase's job and nobody else's: `auto` has
  no fork rounds any more, and `/gantry:implement` hard-refuses on `FORKS:open` under `mode: auto`
  or `unattended`, so a fork waved through here stops the chain later and less informatively. Do
  not reach the terminal question while an entry is unchecked.
- **The task itself is wrong** — the goal is unachievable as stated, or far larger than the
  contract admits → do not quietly shrink it. Set `status: blocked`, say so, and invoke
  `/gantry:handover` to write up what was found. That is a legitimate and useful outcome.

## Report

How many rounds happened and why each one earned itself — or that one round was enough, which on a
narrow change is the phase working rather than the phase skimping.

**Name the agent that produced the critique**, and whether it ran in this invocation or earlier.
Assert that no part of the critique was done inline: that property is this phase's whole reason for
existing separately, and it is worth restating rather than assuming.

Then the decisions: each fork, what was chosen, and anything marked **decided by recommendation,
unconfirmed** — those are the ones the owner did not actually confirm, and burying them would make
this phase's record worse than the count it replaced.

End by naming the next command: `/gantry:implement` on `status: grilled`, or the open fork on
`FORKS:open`.
