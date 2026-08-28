---
name: plan
description: Write the task contract and the implementation plan — task.md and plan.md at the worktree root — asking whatever needs asking before any code is written. Use when the user types "/gantry:plan", or asks to plan a task, write a plan, or work out an approach before implementing.
argument-hint: [task]
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Agent, AskUserQuestion
---

# gantry:plan

Turn a task description into two files at the worktree root: **`task.md`**, the contract — what
this is, when it is done, and what it deliberately is not — and **`plan.md`**, the ordered steps
to get there. Both are committed with the branch, so they travel with the pull request.

Write them **before reading much code and before writing any**. A plan produced after the fact is
a description, not a plan.

This is the first phase of the gantry chain. The next is `/gantry:grill`, which attacks what you
wrote here.

## Ask, don't assume

A plan built on a guessed requirement is worse than no plan, because it looks decided. Use
**AskUserQuestion** whenever a genuine fork would send the work in materially different
directions — storage choice, whether an existing thing is replaced or extended, what happens to
current data, which surface the change belongs on.

Do **not** ask about things the repo answers. Read first, then ask about what reading cannot
settle. One round of questions covering several forks beats a slow drip of one at a time.

If you are running with no human present (a sub-agent dispatched by `gantry:auto-unattended`),
you cannot ask. Record every such fork under **Open questions** in `task.md`, choose the most
conservative reading, and say plainly in your report which choices were assumptions.

## Steps

### 1. Detect the stage

`$GANTRY` is this skill's plugin root — resolve it from this file's own location rather than
hardcoding a path.

```bash
bash "$GANTRY/lib/detect_stage.sh"
```

It prints `ROOT`, `BRANCH`, `TASK`/`PLAN`/`HANDOVER` presence, `STATUS`, `GATES`, `HOOK`, `DIRTY`,
`NEXT`, and a final `PHASE`. Route on what it found:

- `PHASE:not-a-repo` → stop; there is nowhere to write the artifacts.
- **`TASK:absent`** → the normal path. Continue to step 2.
- **`TASK:present`** → a task is already under way. **Never clobber either file.** Read them both,
  then ask whether to revise the existing plan, replace it, or stop because the real next phase is
  `NEXT`. With no human present, revise rather than replace and note it in the report.
- `PHASE:blocked` → read `task.md` first and say what blocked it before planning anything new.

**If `BRANCH` is the repo's default branch**, warn: the plan will be written, but the work wants a
branch. Suggest `/gantry:worktree <name>`. This is a warning, not a refusal — writing a plan on the
mainline harms nothing.

### 2. Write `task.md`

Start from the template, in this order:

1. the target repo's own `docs/templates/task.md`, if it has one;
2. otherwise `$GANTRY/skills/plan/templates/task.md`;
3. otherwise the sections below, inline.

Fill the frontmatter (`id`, `title`, `project`, `branch`, `mode`, `status: planning`) and these
sections **from the task and the conversation, before studying code**:

- **Context & goal** — why this exists and what it is, in a paragraph or two. Enough that someone
  cold knows the problem, not just the instruction.
- **Acceptance criteria** — checkable statements, true or false, no judgement call. "Works well" is
  not a criterion; "the toggle persists across a reload" is.
- **How to verify** — the commands or steps that demonstrate the criteria, plus anything only a
  human can check.
- **Out of scope** — what this deliberately does not do. Write it even when it feels obvious; it is
  the section that stops scope creep later, and `gantry:review` reads it to decide what to defer.

Leave **Affected areas** empty for step 3, and put every unresolved fork under **Open questions**.

### 3. Study the code

Fill **Affected areas** — the files, entry points, and patterns a change here touches, and the
risks it runs into.

When the surface is unfamiliar or wide, dispatch the **explorer** (Agent tool): the repo's
`.claude/agents/explorer.md` if it defines one, otherwise `gantry-explorer`. It is read-only by
tool scope and returns a summary; paste that into Affected areas yourself. When the task is small
and the ground is familiar, read directly instead — and say in the report which you did.

### 4. Write `plan.md`

Ordered steps, each one a change someone could make and check. For each: what changes, where, and
how you will know it worked. Name the files you already know are involved.

Keep it proportionate — a handful of steps for a small task, not an essay. The plan exists to be
executed and to be attacked in the next phase, so favour claims that can be proved wrong over
prose that cannot.

State the test strategy explicitly: what gets a test, what does not, and why.

### 5. Ask what is still open

Put the forks from step 2 and anything code study raised to the user in one **AskUserQuestion**
round. Fold the answers into both files and clear them from **Open questions**.

### 6. Record the status

Set `task.md` frontmatter to `status: planned`. That is what tells `/gantry:grill`, and every
later phase, where this task stands — the phases read it from disk, never from the conversation.

## Report

The branch and worktree, the two file paths, the acceptance criteria in brief, whether an explorer
was dispatched or you read the code yourself, and any question you had to answer by assumption
rather than by asking. End by naming the next command: `/gantry:grill`.
