# gantry:auto orchestration reference

Detail behind `SKILL.md`: how to read the arguments, what each mode changes, and
how the gate resolves. Read this once at the start of a run; the body carries the
stage-by-stage flow.

## Contents

- Arguments and flags
- The two modes
- Checkpoints (supervised)
- Gate resolution
- Reusing worktree and ship
- Failure handling

## Arguments and flags

`$ARGUMENTS` is one string: the task description with optional flags mixed in.
There is no flag parser — read it yourself. Strip the recognised flags out; what
remains, cleaned up, is the task.

| Flag | Effect |
|---|---|
| `--autonomous` | Switch from supervised to autonomous (see below). |
| `--no-pr` | End after push; don't open a PR. Passed through to `gantry:ship`. |
| `--branch <name>` | Use this exact branch name instead of deriving one from the task. |
| `--here` (alias `--on-current`) | Skip worktree creation; run on the branch you're already on. Mutually exclusive with `--branch`. Refuses to run on the repo default branch or a detached HEAD. |
| `--base <branch>` | Override the PR base branch. Passed through to `gantry:ship` (and its detector). Use when the repo integrates somewhere other than the detected default. |

Everything not a flag is the task. Example:
`add a dark-mode toggle to settings --autonomous --branch feat/dark-mode` →
task = "add a dark-mode toggle to settings", autonomous, branch `feat/dark-mode`.

If no task text remains after removing flags, stop and ask what the task is.

### Deriving the branch name

When `--branch` isn't given, derive one from the task: a short kebab-case slug,
prefixed by type when the task makes it obvious — `feat/` for new capability,
`fix/` for a bug, else no prefix. "add a dark-mode toggle" → `feat/dark-mode-toggle`.
Keep it under ~40 chars. `gantry:worktree` validates it and owns the branch/parent
logic from there.

## The two modes

One axis, not two flags. **Supervised** is the default; `--autonomous` is the
override. They differ only in checkpoints and in what a red gate does.

| | Supervised (default) | Autonomous (`--autonomous`) |
|---|---|---|
| Checkpoints | Yes — see below | None; runs unattended |
| Red gate | Report and stop for the user | Iterate to fix, capped at 2 attempts |
| Gate invocation | `run_gates.sh` | `run_gates.sh --strict` |
| No gates found | Continue, flag it (exit 0) | **Stop; refuse to push** (exit 3) |
| Built for | Interactive session | `claude -p "/gantry:auto <task> --autonomous" --dangerously-skip-permissions`, e.g. on a build box or in CI |

The gate (stage 4) is a hard blocker in **both** modes. Autonomous removes the
*human* checkpoints; it never removes the gate. That's the whole design: model
for judgment, script for the guarantee.

### Autonomous preconditions — no blocking prompts

Autonomous runs headless (`claude -p … --dangerously-skip-permissions`), so there
is no human to answer a mid-run question. But the sub-skills `auto` delegates to
can still ask one, which would hang the run:

- **`gantry:worktree`** prompts (AskUserQuestion) when the current branch isn't the
  base, to confirm the parent. Avoid it: start the autonomous run **from the base
  branch** (the repo default), so worktree branches from it without asking. Pass
  `--branch` to fix the name up front too.
- **`gantry:ship`** pauses to ask how to split when it sees several unrelated changes.
  Keep the task single and coherent so the diff is one change; a focused task
  won't trip this.

If a prompt is unavoidable for a given task, that task isn't a fit for
`--autonomous` — run it supervised.

## Checkpoints (supervised)

Two, both using **AskUserQuestion** so the user can redirect in one step:

1. **After the plan (stage 2).** Show the plan and the branch/worktree that were
   created. "Proceed with this plan?" This is also the moment to catch a wrong
   branch name — cheap to recreate now, before any edits.
2. **After review, before anything outward-facing (before stage 6).** Gates are
   green and the review is in hand. "Commit, push, and open the PR?" One gate in
   front of every side effect, since `gantry:ship` won't pause once invoked.

No checkpoint between implement and gate — the gate is the check there, and it's
automatic. In autonomous mode, skip both: proceed straight through, and on a red
gate follow the iterate-capped-at-2 rule instead of stopping.

## Gate resolution

Stage 4 runs `scripts/run_gates.sh` in the worktree — with `--strict` in
autonomous mode, without it supervised. The script, not this skill, decides what
"the gates" are:

1. If the target repo has `.claude/gates.sh`, that file *is* the gate — its exit
   code is used verbatim. This is how a repo reproduces its real CI and overrides
   any heuristic.
2. Otherwise the script auto-detects checks (JS lint/typecheck/build/test,
   Dart/Flutter analyze+test, Python ruff/pytest, Cargo, Go, a Makefile `test`
   target) and runs them — at the repo root **and** in each subproject a bounded,
   depth-limited scan finds (pruning `node_modules`, `build`, `.dart_tool`, etc.).
   A monorepo whose manifests live in subdirs is therefore covered, not missed.
3. If it detects nothing, it prints a `NO-GATES` notice — exit 0 by default, or
   exit 3 under `--strict`.

Exit codes: `0` green · non-zero (1+) a check failed · `2` usage/not-a-repo · `3`
NO-GATES under `--strict`.

You **run** this script; you never reimplement its logic inline. A non-zero exit
blocks push and PR — do not commit-then-push past it, and do not rationalise a
failure as unrelated. If the gate is red (exit 1+):

- **Supervised** → stop, show the failing output, hand it to the user.
- **Autonomous** → read the failure, make a focused fix, re-run the gate. At most
  2 fix attempts. Still red after 2 → stop and report; do not push.

Exit `2` is different from red: the gate *couldn't run* (bad argument, not a git
repo). Don't treat it as a failed check — in autonomous mode it must not consume a
fix attempt. Stop and report the environment problem in either mode. **This is the
orchestrator's own accounting for its inline call only** — see "Hook vs. inline"
below: a registered hook does not carry this exemption, and its block still stands.

`NO-GATES` is handled differently by mode, on purpose:

- **Supervised** (exit 0) → continue, but say so plainly in the report — the run
  had no enforced checks, a weaker guarantee than a green gate; suggest adding
  `.claude/gates.sh`.
- **Autonomous** (exit 3) → **stop and refuse to push.** With no human watching, a
  push of code that ran zero checks is exactly what the gate exists to prevent.
  Report it and suggest `.claude/gates.sh`.

### Hook vs. inline

Some repos (see `gantry:factory`) also register `.claude/hooks/readiness-gate.sh` as a
`Stop`/`SubagentStop` hook. Where one is registered, **the hook is the blocker** —
but only when **both** `.claude/gates.sh` exists at the repo root **and** the task
contract says `status: implementing`; a repo that registers the hook without a
`.claude/gates.sh` gets no enforcement from it. When armed, it runs this same
`run_gates.sh` out of band, and a red result (including the gate's own exit `2` —
the hook does not treat that as a distinct "couldn't run" class the way the inline
call above does) blocks the stop with exit `2` — the model cannot decline it. The
inline `run_gates.sh` call described above is
**belt-and-braces** in that case: it gives you the exit code to journal and reason
about *before* the hook fires, and it is the *only* gate in repos where no hook is
registered. When the two disagree, the hook wins. Never treat a green inline run as
permission to ship if the hook has blocked — this is the same rule stated at
`factory/SKILL.md` stage 6, kept here so both skills point at one place and cannot
drift apart.

**The hook holds no state and blocks a given stop at most once** — no attempt
counter, no lock, nothing written to `task.md`. `stop_hook_active` in the payload is
what stops it from re-blocking the very stop its own previous block caused; that is
the whole of its loop termination. **The retry cap (above), the `status: blocked`
transition, and escalation on repeated failure all live in the orchestrator**, exactly
as they do in a repo with no hook at all — the hook only ever proves a given attempt
green or red, and re-dispatch on red is an orchestrator step either way.

## Reusing worktree and ship

`auto` orchestrates two existing gantry skills rather than duplicating them:

- **Stage 1** invokes `gantry:worktree` for the branch + worktree + parent-fetch
  logic. Don't reimplement worktree creation. The exception is `--here`, which
  skips this entirely and runs on the current branch (guarding against the default
  branch and detached HEAD before proceeding).
- **Stages 6–8** invoke `gantry:ship` for commit → push → PR. Ship is idempotent,
  detects its own stage, matches the *target repo's* commit conventions (which is
  why auto doesn't hardcode gantry's no-trailer style — auto runs in arbitrary
  repos), and reports the terminal PR status. Pass `--no-pr` through to it when
  the user gave `--no-pr`.

Both are un-gated (no `disable-model-invocation`) so `auto` can invoke them. No skill in
gantry carries that flag: a gated skill cannot be invoked by an agent at all, only by a
human typing the command, which would make the pipeline undelegatable. See
`docs/ARCHITECTURE.md` § "Why no skill is model-gated" for the tradeoff that buys.

## Failure handling

Lean on the sub-skills' own guards rather than re-checking everything:

- **Not a git repo / worktree can't be created** → `gantry:worktree` reports it;
  stop and relay.
- **`gh` missing or unauthenticated** → `gantry:ship` still commits and pushes, then
  prints the manual `gh pr create` command. Relay that; don't treat it as fatal.
- **Push rejected (remote moved)** → `gantry:ship` stops rather than force-pushing.
  Relay; the user integrates and re-runs.
- **Branch is the repo default** → without `--here`, auto works on a fresh branch
  via worktree, so this shouldn't arise. With `--here`, Stage 1 checks for it up
  front and stops; if one somehow slips through, ship's `on-default` guard is the
  backstop.
