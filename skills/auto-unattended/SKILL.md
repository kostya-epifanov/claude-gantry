---
name: auto-unattended
description: Runs a task from description to draft pull request with no human in the loop — creates a worktree, drives the gantry chain (plan, grill, implement, review, ship) by invoking each phase skill in turn, keeps a journal.jsonl trail, and treats the repo's checks as the only blocker. Refuses to push if no checks were found. Built for headless use on a build box or in CI. Use when the user types "/gantry:auto-unattended" with a task, or asks to run something unattended, autonomously, or without supervision.
argument-hint: "[task] [--no-pr] [--branch <name>] [--here] [--base <branch>]"
allowed-tools: Bash, Read, Write, Edit, Skill, Agent
---

# gantry:auto-unattended

The gantry chain with nobody watching: worktree → **plan → grill → implement → review** → draft PR.
No checkpoints, no questions, one blocker — the gate.

Built for `claude -p "/gantry:auto-unattended <task>" --dangerously-skip-permissions` on a build box
or in CI. Use `gantry:auto` when you are at the keyboard.

**This skill contains no phase logic** — every phase lives in its own skill, and this one invokes
them. It differs from `gantry:auto` in exactly four things: it never pauses, the gate runs
`--strict`, it keeps a journal, and it opens a **draft** PR.

**You do not dispatch sub-agents; the phases do.** `plan` dispatches the explorer when the surface
warrants it, `grill` always dispatches a fresh critic, `review` dispatches an independent reviewer —
each scoped to its own sub-job and read-only by tool list. `Agent` is in this skill's
`allowed-tools` for that reason alone: frontmatter restricts what is permitted, it does not grant,
so a phase cannot dispatch what the driver has not allowed.

## What "unattended" removes, and what it does not

It removes the **human** checkpoints. It does not remove the gate, and it does not lower the bar
for shipping:

- A red gate is fixed at most **twice**, then the run stops `blocked`. It is never pushed past.
- `NO-GATES` under `--strict` is exit 3 and **refuses to push**. With nobody watching, code that ran
  zero checks must not reach a PR — this is the case the strictness exists for.
- The PR is a **draft**. Nobody reviewed this live, so it must not page reviewers as if someone had.

## Before you start

Read `$GANTRY/skills/auto/references/orchestration.md` — flags, the three modes, how a phase is
invoked, and gate resolution, shared with `gantry:auto` so the two cannot drift. Then read
`references/delegation.md` for the artifacts and the roster, and `references/journal.md` for the
event shapes.

`$GANTRY` is this skill's plugin root — resolve it from this file's own location rather than
hardcoding a path.

## Stage 0 — Arguments and roster preflight

`$ARGUMENTS` is one string; read it yourself. Recognise `--no-pr`, `--branch <name>`, `--here`
(alias `--on-current`), `--base <branch>`; strip them; the remainder is the task. **If no task text
remains, stop and report** — there is nobody to ask.

Then look at what roster this repo will resolve to. The phases do the resolving, but a headless run
should say up front which agents it expects to see:

```bash
ROOT="$(git rev-parse --show-toplevel)"
ls "$ROOT"/.claude/agents/{explorer,critic,reviewer}.md 2>/dev/null
```

Resolution is **per role, repo first**: a phase dispatches `$ROOT/.claude/agents/<role>.md` if it
exists, otherwise `gantry-<role>`. A repo may override one role and inherit the rest. **State what
each role will resolve to before stage 1**, and confirm it in the roll-call at the end against what
the phases actually reported dispatching.

A dispatch that fails with an unknown agent type means the repo's roster was added mid-session and
needs a restart. Stop and report it — do not fall back to doing the work inline.

## Stage 1 — Worktree and branch

Derive a branch name from the task (or take `--branch`), then **invoke `gantry:worktree`**.

Start the run **from the base branch** so worktree doesn't stop to confirm the parent — a prompt
here hangs a headless run. Under `--here`, skip this and run on the current branch, stopping first
on a detached HEAD or the repo's mainline.

Then exclude the journal and gate artifacts from the *main repo's* `.git/info/exclude`:

```
journal.jsonl
.claude/artifacts/
```

and append the first `stage` event.

## Stage 2 — Plan

**Invoke `/gantry:plan`** with the task. It writes `task.md` and `plan.md`, and dispatches the
explorer itself when the surface warrants it.

Set `task.md`'s `mode:` to `unattended` — that is how `implement` and `review` learn to run the gate
`--strict` without being told. **Never clobber an existing `task.md`**: under `--here` a task
already in flight means stop and report, not overwrite.

With no human to ask, `plan` records every genuine fork under *Open questions* and takes the
conservative reading. Carry those forward into your report — they are assumptions, and the reader
of the draft PR needs to know which decisions nobody made.

Journal a `phase` event, naming any sub-agent the phase dispatched. Read `plan.md` back from disk.

## Stage 3 — Grill

**Invoke `/gantry:grill`.** It dispatches a fresh critic against the artifacts on disk — paths, not
contents — and triages what comes back.

This phase matters more here than anywhere else: it is the only scrutiny the plan will get before
implementation, because there is no checkpoint behind it. If grill sets `status: blocked`, **stop**
— journal it, hand over, and report. Do not proceed on a plan that did not survive.

Journal a `phase` event, naming the critic that ran.

## Stage 4 — Implement

**Invoke `/gantry:implement`.** It works from the artifacts on disk, never a restatement of them.

`implement` owns the gate: it sets `status: implementing`, carries out the plan, runs
`run_gates.sh --strict`, and iterates on red at most twice. **Journal a `gate` event with the
literal exit code every time it runs**, with `attempt` incrementing.

- **Green** → continue.
- **Red after 2 attempts** → `status: blocked`. Stop. Do not push.
- **Exit 2** (the gate could not run) → stop and report a broken environment. It must not consume a
  fix attempt.
- **Exit 3** (`NO-GATES` under `--strict`) → stop and refuse to push. Suggest `.claude/gates.sh`.

Do not commit `journal.jsonl` at any point.

## Stage 5 — Review

**Invoke `/gantry:review`.**

It gets an independent read — `/code-review` if available, otherwise a reviewer sub-agent it
dispatches itself — fixes what is clearly in scope, re-runs the gate, and invokes
`gantry:handover` for what it defers. With no human to arbitrate, `review` defers rather than
expands — which is the right default, and means a `handover.md` is the normal outcome here rather
than an exceptional one.

Record which review tier actually ran. If it fell through to self-review, the report must say so:
an unattended run that also reviewed itself has had no independent scrutiny at all.

Journal a `phase` event, naming the tier and any sub-agent it dispatched.

## Stage 6 — Ship

Set `task.md` to `status: shipped` **first**, then **invoke `gantry:ship --draft`**, passing
`--no-pr` and `--base` through if given. That order matters: ship commits the tree, so a status
written afterwards would miss the commit — the PR would carry a stale `status:` and the worktree
would be left dirty.

`task.md`, `plan.md`, and any `handover.md` are committed with the change. `journal.jsonl` and the
gate logs stay excluded.

The PR is a **draft**, always. Journal the final `stage` event once ship returns.

## Stage 7 — Report

Written for someone who was not here, because nobody was:

- The task, the branch, the worktree path, the PR URL — and that it is a draft.
- Which roster each role resolved to, and a delegation roll-call: which agents the phases
  actually dispatched — the explorer if `plan` used one, the critic, the reviewer.
- The gate's exit code on every run, and the number of fix attempts used.
- Whether the readiness hook was **armed or inert**. An unattended run with an inert hook was
  self-policed by a script it could have skipped; say so.
- Which review tier ran, named plainly.
- **Every assumption `plan` had to make** because there was nobody to ask.
- What was deferred, and the `handover.md` path.
- The artifact paths, including `journal.jsonl` for the full trail.

If the run stopped early — blocked gate, blocked plan, `NO-GATES`, broken environment — lead with
that and what would unblock it. A stopped run reported plainly is worth more than a finished one
reported vaguely.
