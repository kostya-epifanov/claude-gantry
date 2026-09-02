---
name: auto
description: Takes a task from a one-line description all the way to an open pull request on its own branch — creates a worktree, then drives the gantry chain (plan, grill, implement, review, ship) by invoking each phase skill in turn. Supervised: it confirms the plan once, then pauses once more before anything outward-facing. The repo's checks are a hard blocker throughout. Pass --no-pr to stop after the push. Use when the user types "/gantry:auto" with a task, or asks to take a task end to end or to "just do this and open a PR".
argument-hint: "[task] [--no-pr] [--branch <name>] [--here] [--base <branch>]"
allowed-tools: Bash, Read, Write, Edit, Skill, Agent, AskUserQuestion
---

# gantry:auto

One command from a task description to an open pull request, supervised. It creates the branch and
worktree, then walks the gantry chain — **plan → grill → implement → review → ship** — invoking
each phase skill in turn and pausing twice for you.

**This skill contains no phase logic.** Planning, grilling, implementing, reviewing, and shipping
each live in their own skill, and this one invokes them — the same commands you would type. That is
deliberate: the same phases run whether you type them yourself, run them here, or run them
unattended, so they cannot drift into three subtly different pipelines.

**You do not dispatch sub-agents; the phases do.** `plan` dispatches the explorer when the surface
warrants it, `grill` always dispatches a fresh critic, `review` dispatches an independent reviewer.
Each of those is scoped to its own sub-job and is read-only by tool list. `Agent` stays in this
skill's `allowed-tools` for that reason and no other: a skill's frontmatter restricts what is
permitted, it does not grant, so a phase cannot dispatch what the driver has not allowed.

For an unattended run to a draft PR, use `gantry:auto-unattended`. To drive it yourself, type the
phase skills in order.

## Before you start

Read `references/orchestration.md` — flags, the three modes, how a phase is invoked, where the
checkpoints sit, and how the gate resolves. It is shared with `gantry:auto-unattended` so the two
cannot drift.

`$GANTRY` is this skill's plugin root — resolve it from this file's own location rather than
hardcoding a path.

## Stage 0 — Arguments

`$ARGUMENTS` is one string; there is no parser, so read it yourself. Recognise `--no-pr`,
`--branch <name>`, `--here` (alias `--on-current`), and `--base <branch>`; strip them; what remains
is the task. `--here` and `--branch` are mutually exclusive — `--here` wins. If no task text
remains, ask what the task is.

State the task, the mode, and the flags back in one line before doing anything.

## Stage 1 — Worktree and branch

Derive a branch name from the task (or take `--branch`), then **invoke `gantry:worktree`** with it.
Let worktree own branch validation, the parent fetch, and entering the worktree — don't reimplement
any of it.

Under `--here`, skip this entirely and run on the current branch. Stop first if HEAD is detached or
you are on the repo's mainline (`origin/HEAD`); `develop` is a valid `--here` target.

## Stage 2 — Plan

**Invoke `/gantry:plan`** with the task.

It writes `task.md` and `plan.md` at the worktree root, and decides for itself whether the surface
needs the explorer. Read both files back from disk before moving on — a plan you remember writing
is not the plan on disk, and every later phase reads the file.

Set `task.md`'s `mode:` to `auto`, so `implement` and `review` resolve the right gate strictness
without being told.

**Then settle the forks, before grill.** Run `bash "$GANTRY/lib/detect_stage.sh"` and read
`FORKS:`. On **`FORKS:open`**, put every open entry to the user in **one AskUserQuestion round** —
one question per fork, the options phrased as what each choice would actually cost. Fold the
answers into `task.md` and `plan.md`, check each entry off in place (`- [x] <fork> — <decision>`),
and only then continue.

This is the cheap moment, and it is the whole reason the round happens here rather than at the
stage 4 checkpoint. A fork settled now costs a sentence; the same fork discovered at review has an
implementation built on top of it. Do not answer one yourself, and do not carry one past this
point — `/gantry:implement` refuses on an open fork under `mode: auto`, so a fork waved through
here stops the chain later and less usefully.

On `FORKS:unknown`, say the section is missing and continue.

## Stage 3 — Grill

**Invoke `/gantry:plan-grill`.**

It dispatches a fresh critic against the artifacts on disk and triages what comes back. That
delegation is the skill's own central rule — it happens in every mode, including this one, and it
is not yours to arrange or to skip. Read the revised `plan.md` back from disk.

If grill set `status: blocked`, stop here and surface the reason. A plan that did not survive
critique is a result, not a failure to route around.

**Check `FORKS:` again.** Grill can open a fork that planning never had — a critique that finds a
genuine design decision nobody made records it rather than absorbing it. Run the same
AskUserQuestion round as stage 2 on `FORKS:open`, and fold the answers back into both files. The
stage 2 check does not cover this; it ran before the critic did.

**Then set `status: grilled` yourself.** When grill opens a fork it deliberately leaves the status
alone, so it returns with `planned` — and unlike stage 2 there is no later phase to repair that.
Settling the forks here without writing the status leaves the chain claiming the plan was never
grilled, and stage 5's `/gantry:implement` warns about a phase that in fact ran.

## Stage 4 — Checkpoint: confirm the plan

**AskUserQuestion.** Show the plan as grilled, what the critique changed, and the branch and
worktree that were created. "Proceed with this plan?"

This is also the moment to catch a wrong branch name — cheap to recreate now, before any edits.

## Stage 5 — Implement

**Invoke `/gantry:implement`.**

`implement` owns the gate. It sets `status: implementing` before editing (which arms the readiness
hook), carries out the plan, and runs `run_gates.sh`. **Do not run the gate yourself and do not
route around a red one.** If it comes back red or blocked, stop and hand the failure to the user —
supervised mode does not iterate on a red gate.

Take from its report: the gate's exit code, and whether the hook's firing conditions were
**met or unmet**. Both go in your final report verbatim.

## Stage 6 — Review

**Invoke `/gantry:review`.**

It gets an independent read of the diff — `/code-review` if available, otherwise a reviewer
sub-agent it dispatches itself — then fixes what is clearly in scope, re-runs the gate after any
fix, and invokes `gantry:handover` for anything it deferred. Read back which of its three tiers
actually ran; if it fell through to self-review, your report must say so.

If review set `status: blocked`, stop and surface it.

## Stage 7 — Checkpoint: confirm the side effects

**AskUserQuestion.** The gate is green and the review is in hand. "Commit, push, and open the PR?"

One gate in front of every side effect, since `gantry:ship` won't pause once invoked.

## Stage 8 — Ship

Set `task.md` to `status: shipped` **first** — ship commits the tree, so a status written
afterwards would miss the commit and leave the chain reading as unshipped. Then **invoke
`gantry:ship --reviewed`.** It is exactly this tail — idempotent, stage-detecting, and it matches
the *target repo's* commit conventions rather than gantry's. Pass `--no-pr` and `--base` through if
they were given.

`--reviewed` is not optional here. Ship runs its own `/code-review --fix` stage for callers who
reach it directly; stage 6 already reviewed this change, and a second pass would let `--fix` apply
findings `/gantry:review` deliberately deferred to `handover.md`.

`task.md`, `plan.md`, and any `handover.md` are committed with the change; they are the record of
what was decided and what was left.

`gantry:auto` opens a **ready-for-review** PR. You were in the room for the review, so it does not
need to arrive as a draft.

## Stage 9 — Report

The task and the mode. The branch and worktree path. Which sub-agents the phases actually
dispatched — the explorer if `plan` used one, and which critic ran. **Every fork that was put to
the user and what they decided** — those are the decisions that shaped the work, and they exist
nowhere else once the round closes. What the critique changed. The
gate's exit code and whether the readiness hook's firing conditions were met — which is not the
same as the hook having run, since registration is not visible to the detector. Which review tier ran, plainly
named. What was deferred and the `handover.md` path if there is one. The commit, the push, and the
PR URL.

Be honest about anything skipped, unverified, or self-reviewed. A report that reads cleaner than the
run went is the one failure this chain cannot catch.
