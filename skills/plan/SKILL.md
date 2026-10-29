---
name: plan
description: Write the task contract and the implementation plan — task.md and plan.md at the worktree root — asking whatever needs asking before any code is written. Use when the user types "/gantry:plan", or asks to plan a task, write a plan, or work out an approach before implementing.
argument-hint: [task] [--task <id>] [--lead <session>]
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Agent, AskUserQuestion, SendMessage
---

# gantry:plan

Turn a task description into two files at the worktree root: **`task.md`**, the contract — what
this is, when it is done, and what it deliberately is not — and **`plan.md`**, the ordered steps
to get there. Neither is committed — they are the run's working state, not the change. What the
reviewer needs from `task.md` reaches the pull request because `gantry:ship` quotes it into the
body; step 2 below is what keeps both files out of git in the first place.

Write the task's **intent** — what this is, when it is done, how it will be checked — before
reading much code, and all of it before writing any. A plan produced after the fact is a
description, not a plan, and criteria written to fit what the code turned out to make easy are not
criteria.

Two sections are the exception: *Out of scope* and *Affected areas* wait for the code study in
step 3, and are written in step 4. Knowing what a change touches is what tells you what it deliberately will not
touch, so writing the boundary from the task description alone is guessing — and both
`gantry:review` and `gantry:handover` then read that guess as a contract.

This is the first phase of the gantry chain. The next is `/gantry:grill`, which chains a cold
critique of what you wrote here and then settles the approach with the user.

## Ask, don't assume

A plan built on a guessed requirement is worse than no plan, because it looks decided. Use
**AskUserQuestion** whenever a genuine fork would send the work in materially different
directions — storage choice, whether an existing thing is replaced or extended, what happens to
current data, which surface the change belongs on.

Do **not** ask about things the repo answers. Read first, then ask about what reading cannot
settle. One round of questions covering several forks beats a slow drip of one at a time.

**If you were invoked with `--task <id>`** (a driver passes it through; strip it from the task), that
is the tracker id this run carries, and it is the `id` you write in step 2.

**If you were invoked with `--lead <session>`** (`gantry:auto` passes it through; strip it from the
task), every question this skill asks goes to that lead instead, as a `fork`, following
`$GANTRY/skills/auto/references/lead.md`. That covers step 1's question as well as step 6's round.
Offer step 1's answers as `Revise`, `Replace` and `Leave it`, never `stop`, because a lead's `stop`
ends the run. It applies from step 1, before `task.md` records the lead.

If you are running with no human present (a sub-agent dispatched by `gantry:auto-unattended`), you
cannot ask — and you must not answer it yourself either. Record every such fork under **Open
questions** in `task.md` as an unchecked item and **leave it open**. Do not pick the conservative
reading and continue: an assumption written into a plan looks exactly like a decision, and by the
time it surfaces the implementation is built on it.

An open fork is a **precondition**, not a note — but it is no longer *this* phase's precondition.
Step 7 marks the plan `planned` with forks open, because drafting is what this phase finishes. What
an open fork blocks is **dispatch**, and two later guards read the forks directly to enforce that:
`/gantry:grill` will not reach its approval while an entry is unchecked, and `/gantry:implement`
hard-refuses on `FORKS:open` when a driver dispatched it. Supervised runs settle the fork inside
grill's rounds; unattended runs stop and escalate. Neither outcome is yours to pre-empt by
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
- **`TASK:inherited`** → the file on disk is the **previous** task's contract. gantry no longer
  commits `task.md`, so this can only appear in a repository that ran 0.4.x or earlier and still
  carries a merged `task.md` on its base branch — a branch cut from it is born holding the last
  merged one, and nothing is under way here. **This is a clean start:** write both files fresh, do
  not ask, and do not revise. Continue to step 2. Mention in the report that the base branch still
  carries a committed `task.md` from an older gantry, and that `git rm task.md plan.md` on the base
  retires this state for good.

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

**First, keep it out of git.** `task.md`, `plan.md`, `handover.md` and `review.md` are the chain's
working state, not the change, and they are never committed — see `docs/ARCHITECTURE.md` § *The artifact
contract*. Assert that before writing the first one, so the file is excluded from the moment it
exists rather than after `ship` has already had a chance to sweep it in with `git add -A`:

```bash
bash "$GANTRY/lib/ensure_excluded.sh" /task.md /plan.md /handover.md /review.md /qa.md
```

The leading `/` anchors each pattern to the worktree root, so a repo with its own `docs/task.md` or
`specs/plan.md` is untouched. `review.md` is written by `gantry:review`, two phases from now; it is
asserted here all the same, because `scripts/verify.sh` holds every call that names one of these to
naming all four. It writes to `.git/info/exclude`, which is untracked — **never**
`.gitignore`, which would put an edit to a tracked file in the user's pull request. The script is
idempotent and race-safe, so running it on every plan costs nothing and two lanes doing it at once
still leave one copy of each line.

One thing it cannot do: a pattern does not untrack a file git already tracks. In a repository that
ran 0.4.x the first three may be **committed on the base branch**, in which case they will still show
as modified rather than ignored. That is the `TASK:inherited` case above; say so, and leave the
`git rm` to the user.

Then start from the template, in this order:

1. the target repo's own `docs/templates/task.md`, if it has one;
2. otherwise `$GANTRY/skills/plan/templates/task.md`;
3. otherwise the sections below, inline.

Fill the frontmatter (`id`, `title`, `project`, `branch`, `mode`, `status: planning`, and
`lead: <session>` when you were given one) and these
sections **from the task and the conversation, before studying code**. The `id` is the tracker id
when the run has one — `--task <id>` from a driver, or, typed by hand, what `lib/task_id.sh` reports
when you write the task text to a file and run it with `--args-file` (an id at the start of the
text, or a tracker URL in it) — and `YYYY-MM-DD-<slug>` otherwise. It is what `journal_append.sh
--task` records and what `gantry:ship` puts at the front of the PR title, so a tracker id here is
how the PR reaches the issue. On a revise, keep the existing one. These sections are the task's
intent, and they must not be shaped by what the code turns out to make convenient:

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
  runs into. **Strip trailing line numbers from any markdown path** as you paste — `scripts/verify.sh`
  fails an `.md:<line>` citation, and it reads `task.md` while it is still untracked, so an
  unstripped one goes red at the next gate. The explorer is told this too, but it is not the only
  thing whose output lands here.
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

### 6. Ask only what you cannot draft without

**`/gantry:grill` is the asking moment now, not this step.** Record every fork under *Open
questions* and leave it open — which was already this skill's behaviour with no human present, and
is now the default with one. Grill explains the problem, puts the forks to the user in priced
options, and writes the decisions to disk.

That leaves this step a narrow job: ask only what blocks *drafting*. If you genuinely cannot write
a coherent plan without an answer — the task names two systems and you cannot tell which one it
means — ask, in one **AskUserQuestion** round. Anything you can draft around is a fork, not a
blocker, and recording it costs a line while asking it costs a round-trip the user did not need to
spend twice.

When you do settle something, **check each entry off in place** —
`- [x] <the fork> — <what was decided>`. Do not delete a settled fork. A deleted entry is
indistinguishable from one that was never raised, and the next reader cannot tell a decision from an
oversight. The record of what was asked and answered is most of what this section is for.

### 7. Record the status

Run the detector again and read its **`FORKS:`** line. It, not your recollection, decides whether
this plan may leave the stage:

**Set `status: planned` once the draft is complete — whether or not a fork is open.** `planned`
means *drafted*: these two files say what the task is and how it would be done. It deliberately does
**not** mean an implementer may be dispatched. The chain now spells that out across three values —
`planned` drafted, `critiqued` a critic read it, `grilled` a human agreed and the forks are closed —
and only the last one is an approval.

This is a change from the rule that held through 0.6.x, where an open fork kept the status at
`planning`. It had to move: step 6 now records forks rather than asking them, so `FORKS:open` is the
*normal* exit from planning, and `planning` routes to `NEXT:/gantry:plan` — the chain's own signpost
pointing back at the phase that just finished. What protects dispatch is not this status but
`/gantry:implement`, which hard-refuses on `FORKS:open` under `mode: auto` or `unattended`, and
`/gantry:grill`, which will not reach its approval while an entry is unchecked. Two guards that read
the forks directly, rather than a status standing in for them.

So:

- **`FORKS:none` or `FORKS:open`** → `status: planned`, and **report the open forks either way**. A
  plan that correctly identifies a decision nobody has made is the phase working, not failing.
- **Still drafting** — a section you could not write, a question from this step unanswered → leave
  `status: planning`. That is what `planning` is for now: an unfinished draft, not a finished one
  with questions attached.
- **`FORKS:unknown`** → the file has no *Open questions* heading, so nothing can be checked. Warn,
  say the section is missing, and continue.

## Report

The branch and worktree, the two file paths, the acceptance criteria in brief, whether an explorer
was dispatched or you read the code yourself, and the **`FORKS:` value with the count of open
forks** — listing each one, if any survived. A fork left open is the single most important thing in
this report: it is what stops the chain, and the reader needs to know what decision is waiting.

End by naming the next command: **`/gantry:grill`**, which chains the cold critique itself and then
puts every open fork to the user. Say how many forks are waiting there, so the reader knows what the
conversation is for before it starts.
