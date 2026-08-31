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

Write the task's **intent** — what this is, when it is done, how it will be checked — before
reading much code, and all of it before writing any. A plan produced after the fact is a
description, not a plan, and criteria written to fit what the code turned out to make easy are not
criteria.

Two sections are the exception: *Out of scope* and *Affected areas* wait for the code study in
step 3, and are written in step 4. Knowing what a change touches is what tells you what it deliberately will not
touch, so writing the boundary from the task description alone is guessing — and both
`gantry:review` and `gantry:handover` then read that guess as a contract.

This is the first phase of the gantry chain. The next is `/gantry:grill`, which attacks what you
wrote here.

## Ask, don't assume

A plan built on a guessed requirement is worse than no plan, because it looks decided. Use
**AskUserQuestion** whenever a genuine fork would send the work in materially different
directions — storage choice, whether an existing thing is replaced or extended, what happens to
current data, which surface the change belongs on.

Do **not** ask about things the repo answers. Read first, then ask about what reading cannot
settle. One round of questions covering several forks beats a slow drip of one at a time.

If you are running with no human present (a sub-agent dispatched by `gantry:auto-unattended`), you
cannot ask — and you must not answer it yourself either. Record every such fork under **Open
questions** in `task.md` as an unchecked item and **leave it open**. Do not pick the conservative
reading and continue: an assumption written into a plan looks exactly like a decision, and by the
time it surfaces the implementation is built on it.

An open fork is a **precondition**, not a note. While one is on the page the plan is not
dispatchable, and step 7 will not mark it so. The driver decides what happens next — supervised
puts the forks to the user, unattended stops the run — but neither outcome is yours to pre-empt by
guessing.

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
- **`TASK:inherited`** → the file on disk is the **previous** task's contract. gantry commits
  `task.md` with every pull request, so a branch cut from the base branch is born holding the
  last merged one — nothing is under way here. **This is a clean start:** write both files
  fresh, do not ask, and do not revise. Continue to step 2.

  Overwriting a contract is normally the one thing this step forbids, so it is worth saying what
  makes this safe: the detector *establishes* the value rather than guessing it — `task.md` must be
  byte-identical to the copy at the merge-base with the base branch **and** carry a terminal
  status. Every case it cannot establish, including a missing merge-base, an unresolvable base
  branch and a detached `HEAD`, reports `present` instead.

  What is proven finished and unedited is **`task.md`** — that is the only file the check reads.
  `plan.md` is inherited alongside it in the ordinary case and is overwritten on the same
  judgement, so if you find a `plan.md` that someone has clearly worked on, stop and ask even
  though the value says `inherited`.
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
sections **from the task and the conversation, before studying code** — this is the task's intent,
and it must not be shaped by what the code turns out to make convenient:

- **Context & goal** — why this exists and what it is, in a paragraph or two. Enough that someone
  cold knows the problem, not just the instruction.
- **Acceptance criteria** — checkable statements, true or false, no judgement call. "Works well" is
  not a criterion; "the toggle persists across a reload" is.
- **How to verify** — the commands or steps that demonstrate the criteria, plus anything only a
  human can check.

Leave **Out of scope** and **Affected areas** empty for step 4 — both are written from what the
code study finds.

Then put every unresolved fork under **Open questions**, each one a **checkbox**, because
`lib/detect_stage.sh` reads that section and every later phase routes off its answer:

- `- [ ] <the fork>` — open. Nothing may be dispatched against it.
- `- [x] <the fork> — <the decision, and what settled it>` — decided.

A bullet with no box at all reads as **open**, deliberately: a fork someone forgot to mark should
block rather than pass silently. Anything that is not a list item is prose and is ignored, so an
empty section, or one that just says `None.`, is settled.

### 3. Study the code

Find out what a change here actually touches: the files, the entry points, the patterns already in
play, the callers of what is being changed, and the risks. Answer "which files" before you answer
"what to write in them".

When the surface is unfamiliar or wide, dispatch the **explorer** (Agent tool): the repo's
`.claude/agents/explorer.md` if it defines one, otherwise `gantry-explorer`. It is read-only by
tool scope and returns a summary. When the task is small and the ground is familiar, read directly
instead — and say in the report which you did.

Take back a summary, not the material. What you write into `task.md` in the next step is your own
sentence, not the agent's transcript.

### 4. Write **Out of scope** and **Affected areas**

Both, now, from what step 3 found — which is why they were left empty in step 2.

- **Affected areas** — the files, entry points and patterns in play, and the risks a change here
  runs into.
- **Out of scope** — what this deliberately does not do. Write it even when it feels obvious.

They belong in the same step because they are the same knowledge read twice: what a change touches
is exactly what tells you what it will not touch. Written from the task description alone, *Out of
scope* is a guess — and it is not treated as one downstream: `gantry:review` triages every finding
against it to decide what to defer, and `gantry:handover` quotes it. A boundary nobody checked
against the code is worse than none, because it reads as decided.

### 5. Write `plan.md`

Ordered steps, each one a change someone could make and check. For each: what changes, where, and
how you will know it worked. Name the files you already know are involved.

Keep it proportionate — a handful of steps for a small task, not an essay. The plan exists to be
executed and to be attacked in the next phase, so favour claims that can be proved wrong over
prose that cannot.

State the test strategy explicitly: what gets a test, what does not, and why.

### 6. Ask what is still open

Put the forks from step 2 and anything code study raised to the user in one **AskUserQuestion**
round. Fold the answers into both files, then **check each entry off in place** —
`- [x] <the fork> — <what was decided>`.

Do not delete a settled fork. A deleted entry is indistinguishable from one that was never raised,
and the next reader cannot tell a decision from an oversight. The record of what was asked and
answered is most of what this section is for.

### 7. Record the status

Run the detector again and read its **`FORKS:`** line. It, not your recollection, decides whether
this plan may leave the stage:

- **`FORKS:none`** → set `task.md` frontmatter to `status: planned`. That is what tells
  `/gantry:grill`, and every later phase, where this task stands — the phases read it from disk,
  never from the conversation.
- **`FORKS:open`** → **leave `status: planning`** and report the open forks. `planned` is the
  assertion that an implementer may be dispatched against this plan, and while a fork is open that
  assertion is false. This is not a failure of the phase; a plan that correctly identifies a
  decision nobody has made is the phase working.
- **`FORKS:unknown`** → the file has no *Open questions* heading, so nothing can be checked. Warn,
  say the section is missing, and continue.

## Report

The branch and worktree, the two file paths, the acceptance criteria in brief, whether an explorer
was dispatched or you read the code yourself, and the **`FORKS:` value with the count of open
forks** — listing each one, if any survived. A fork left open is the single most important thing in
this report: it is what stops the chain, and the reader needs to know what decision is waiting.

End by naming the next command: `/gantry:grill` on `FORKS:none`, or the fork itself on
`FORKS:open` — there is nothing to grill a plan for until someone decides.
