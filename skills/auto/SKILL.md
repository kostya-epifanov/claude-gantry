---
name: auto
description: Takes a task from a one-line description all the way to an open pull request on its own branch — creates a worktree, plans, implements, runs the repo's gates as a hard blocker, reviews the diff, then commits, pushes, and opens a PR. Supervised by default (confirms the plan, then pauses once before anything outward-facing); --autonomous runs unattended with the gate as the only blocker; --no-pr stops after push. Use when the user types "/gantry:auto" with a task description, or asks to take a task end to end, to "just do this and open a PR", or to run a task autonomously.
argument-hint: "[task] [--autonomous] [--no-pr]"
allowed-tools: Bash, Read, Edit, Write, Skill, Agent
---

# gantry:auto

Take a task from description to open PR without leaving the rails. `auto` doesn't do the
work in some special way — it runs the *same* chain you'd run by hand, in order, with one
non-negotiable checkpoint: a gate script whose exit code decides whether anything gets
pushed.

**The principle: model for judgment, script for the guarantee.** Planning, implementing,
and fixing are yours to reason through. But "never push if the checks are red" is not a
promise prose can keep — the model can always talk itself past a sentence. So that one
guarantee lives in `scripts/run_gates.sh`'s exit code, and this skill treats it as law.

`auto` is manual-only (you invoke it) and orchestrates two existing gantry skills rather than
reinventing them: `gantry:worktree` for the branch, `gantry:ship` for commit → push → PR.

`$GANTRY` is this skill's plugin root — resolve it from this file's own location (the way the
`status` and `ship` skills do), never a hardcoded path.

## Before you start

Read [references/orchestration.md](references/orchestration.md) once. It has the flag
rules, the exact difference between the two modes, where the checkpoints fall, and how the
gate resolves — this body assumes it.

## Stage 0 — Read the arguments and pick the mode

`$ARGUMENTS` is the task plus optional flags, as one string; there is no parser, so read it
yourself. Recognise `--autonomous`, `--no-pr`, `--branch <name>`, `--here` (alias
`--on-current`), `--base <branch>`; strip them out; what remains is the task. Empty task after stripping → ask
what the task is. `--here` and `--branch` are mutually exclusive — `--here` uses the branch
you're already on; if both appear, prefer `--here` and note the ignored `--branch`.

- **Supervised** (default): checkpoints on, a red gate stops for the user.
- **Autonomous** (`--autonomous`): no checkpoints, a red gate triggers a capped fix loop.

State the resolved task, mode, and flags back in one line before proceeding, so the run's
intent is on the record.

## Stage 1 — Worktree + branch

**Default (fresh branch).** Derive a branch name from the task (or use `--branch`), then
**invoke `gantry:worktree`** with it. Let worktree own branch validation, the parent fetch, and
entering the worktree — don't reimplement any of that. Everything downstream happens inside
the worktree it creates.

**`--here` (work on the current branch).** Skip `gantry:worktree` entirely and run the rest of
the chain in the branch/worktree you're already in — for accumulating onto an existing branch
(an RC line, a colleague's branch) rather than starting a new one. First confirm it's a valid
target:

- **Detached HEAD, or on the repo's default mainline** (`origin/HEAD`, i.e. typically
  `main`/`master`) → **stop**: you'd be committing onto the mainline and there's no branch to
  PR from against itself. Tell the user to start a branch (`--branch <name>` or
  `/gantry:worktree <name>`) and re-run. (An integration branch like `develop` is a *valid* target
  — accumulating onto an RC line is the point of `--here`.) `gantry:ship`'s `ON_DEFAULT` guard is
  the backstop if this check is ever bypassed.
- Otherwise use the current branch as-is and continue to Stage 2. Note in the report that the
  run targeted an existing branch (no worktree was created).

## Stage 2 — Plan

Write a short implementation plan: the files you expect to touch and the approach, a handful
of bullets, not an essay. Keep it proportional to the task.

**Supervised checkpoint.** Show the plan and the branch/worktree, and ask to proceed
(AskUserQuestion). This is the cheap moment to fix a wrong branch name or redirect the
approach. **Autonomous:** skip; continue straight to stage 3.

## Stage 3 — Implement

Make the edits. Freeform — this is ordinary work, no special ceremony. Stay within the
task's scope; if you discover the task is really several unrelated changes, note it (and in
supervised mode raise it), rather than quietly ballooning the diff.

## Stage 4 — Gate (the hard blocker)

Run the gate script from inside the worktree. **In autonomous mode pass `--strict`;**
supervised runs it without:

```bash
bash "$GANTRY/skills/auto/scripts/run_gates.sh"            # supervised
bash "$GANTRY/skills/auto/scripts/run_gates.sh" --strict   # autonomous
```

Its **exit code is the contract**: `0` green · `1`+ a check failed (red) · `2` the gate
couldn't run (bad usage / not a git repo) · `3` NO-GATES under `--strict`. It runs the repo's
own `.claude/gates.sh` if present, else auto-detects
checks — at the repo root **and in each subproject** it finds, so a monorepo whose manifests
live in subdirs (`app/pubspec.yaml`, `landing/package.json`) is covered — else prints
`NO-GATES`. Do not reimplement its logic, and do not push past a non-zero exit. If the target repo
registers a readiness-gate hook (see `gantry:factory`), that hook is the blocker and this inline run
is belt-and-braces; in every other repo this script is the only gate.

- **Red (exit 1+), supervised** → stop. Show the failing output; hand it to the user. The run
  ends here.
- **Red (exit 1+), autonomous** → read the failure, make a focused fix, re-run the script.
  **At most 2 fix attempts.** Still red after the second → stop and report; nothing gets pushed.
- **Exit 2 (couldn't run), either mode** → not a red check but a broken invocation or
  environment. Stop and report; don't spend an autonomous fix attempt trying to "fix" it.
- **`NO-GATES`, supervised (exit 0)** → the run had no enforced checks. Continue, but flag it
  in the report — a weaker guarantee than a green gate.
- **`NO-GATES`, autonomous (exit 3)** → **stop; do not push.** Unattended, code that ran zero
  checks must not reach a PR. Report that no gates were found and the run refused to push;
  suggest adding `.claude/gates.sh`.

## Stage 5 — Review

Get an **independent** read of the diff — not the same reasoning that wrote it grading its own
homework. Use the first of these that's available, and **always name in the report which one
ran**:

1. **`/code-review` (default).** The purpose-built reviewer — it runs outside the authoring
   context and verifies its own findings, dropping the ones it can't confirm. Prefer it
   whenever it's invocable here.
2. **Independent review subagent.** If `/code-review` isn't available, launch a subagent
   (**Agent** tool) to review the diff on its own — give it the diff (`git diff <base>...HEAD`)
   and the task, and ask for correctness/security/scope findings ranked by severity. A fresh
   context is the point: it catches what the author rationalised past.
3. **Self-review, last resort.** If neither is available, review the diff yourself against the
   task — and **disclose in the report that the review was a self-review**, a weaker check.

In supervised mode, surface the findings before the next checkpoint. Address anything clearly
worth fixing; re-run the gate (stage 4) if a fix could affect it. In autonomous mode, apply the
clear-cut fixes and note the rest in the report — don't loop on subjective review points.

## Stages 6–8 — Commit, push, PR

**Invoke `gantry:ship`.** It is exactly this tail — idempotent, stage-detecting, and it matches
the *target repo's* commit conventions (which is why `auto` doesn't impose gantry's own
commit style: it runs in arbitrary repos). Pass `--no-pr` through when the user gave it, to
stop ship after the push; pass `--base <branch>` through when given, so the PR targets it.

**Supervised checkpoint — before invoking ship.** Gates are green, the review is in hand.
Ask once: commit, push, and open the PR? (AskUserQuestion.) This is the single gate in front
of every outward-facing action, since ship won't pause once it's running. **Autonomous:**
skip the ask; invoke ship directly.

Let ship's own guards handle the edge cases — `gh` missing/unauthenticated (it prints the
manual command), a rejected push (it stops rather than force-pushing). Relay what it reports.

## Stage 9 — Report

One consolidated summary of what actually happened:

- **Task** and **mode**.
- **Branch** and **worktree path** (from stage 1).
- **Gate result** — green / red / no-gates, and for autonomous, how many fix attempts.
- **Review** — **who reviewed** (`/code-review` / independent subagent / self-review),
  the key findings, and what you did about them.
- **Commit SHA**, **push** status, and **PR URL** (from ship), or the last stage reached and
  why it stopped.

Be honest about anything skipped, unverified, or stopped short. A run that halted at a red
gate is a *successful* gate doing its job — report it as such, not as a failure.
