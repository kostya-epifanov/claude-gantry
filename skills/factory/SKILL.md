---
name: factory
description: Runs a task through the gantry multi-agent orchestrator — writes an on-disk task.md contract, delegates exploring, planning, and implementing to the scoped sub-agent roster via the Task tool, keeps a journal.jsonl trail, runs the repo's gates as a hard blocker, reviews, then commits, pushes, and opens a PR. Supervised by default; --autonomous runs unattended with the gate as the only blocker; --no-pr stops after push. Use when the user types "/gantry:factory" with a task, or asks to run something through the orchestrator, the factory, or the multi-agent pipeline. Ships its own roster, and prefers the repo's .claude/agents/ when it defines one — for a plain single-context task-to-PR run, gantry:auto is the right skill instead.
argument-hint: "[task] [--autonomous] [--no-pr]"
allowed-tools: Bash, Read, Edit, Write, Skill, Agent, AskUserQuestion
---

# gantry:factory

Run a task through the gantry orchestrator: an on-disk contract, work delegated to scoped
sub-agents, a journal of what happened, and a gate that decides whether any of it ships.

`gantry:auto` runs the same pipeline in **one context** — it is the portable version, and for most
tasks in most repos it is the right one. `factory` differs in exactly two ways, and they are the
whole point:

- **The orchestrator coordinates; it does not do.** Exploring, planning, and implementing are
  dispatched to a scoped roster, each agent with its own tools and its own context. Your
  context holds summaries and verdicts, never file dumps.
- **The run has an on-disk contract.** `task.md`, `plan.md`, and `journal.jsonl` in the worktree
  mean handoff survives a restart, and a human can read what the run believed it was doing.

What does **not** change: the gate is still a script whose exit code is law. Model for judgment,
script for the guarantee.

## Before you start

Read [references/task-contract.md](references/task-contract.md) once — the artifacts, the
delegation map, the journal protocol, and the context-hygiene rule. This body assumes it.

Flags, the two modes, checkpoint placement, and how the gate resolves are **identical to
`gantry:auto`** and documented once in `skills/auto/references/orchestration.md`.
Read that too rather than guessing; nothing here overrides it.

## Stage 0 — Arguments, mode, and the roster preflight

`$ARGUMENTS` is the task plus optional flags in one string; there is no parser, so read it
yourself. Recognise `--autonomous`, `--no-pr`, `--branch <name>`, `--here` (alias `--on-current`),
`--base <branch>`; strip them out; what remains is the task. Empty task after stripping → ask what
the task is. Flag semantics are `gantry:auto`'s, unchanged.

- **Supervised** (default): checkpoints on, a red gate stops for the user.
- **Autonomous** (`--autonomous`): no checkpoints, a red gate triggers a capped fix loop.

**Then resolve the roster.** gantry ships `gantry-explorer`, `gantry-planner`, and
`gantry-implementer`; they install with the plugin and need no setup, so a run is never blocked on
a missing roster. But a repo that has tuned its own agents knows its codebase better than gantry
does, so **the repo's roster wins when it exists**. Resolve against the repo root, not the working
directory — `/gantry:factory` gets invoked from subdirectories all the time:

```bash
ROOT="$(git rev-parse --show-toplevel)"
ls "$ROOT"/.claude/agents/{explorer,planner,implementer}.md 2>/dev/null
```

Per role, independently: if `$ROOT/.claude/agents/<role>.md` exists, dispatch `<role>`; otherwise
dispatch `gantry-<role>`. A repo may override one role and inherit the rest.

State the resolved task, mode, flags, and **which roster each role resolved to**, in one line — so
the run's intent is on the record before it starts.

## Stage 1 — Worktree + branch

Identical to `gantry:auto`. Derive a branch name from the task (or use `--branch`), then **invoke
`gantry:worktree`** with it; let worktree own branch validation, the parent fetch, and entering the
worktree. Everything downstream happens inside it.

**`--here`** skips worktree creation and runs on the current branch — but **stop** if that branch
is the repo's default mainline (`origin/HEAD`) or HEAD is detached: there would be no branch to
PR from. An integration branch like `develop` is a valid target.


## Stage 2 — The task contract

Write `task.md` at the worktree root, from the repo's `docs/templates/task.md` when it exists and
from the skeleton in the reference otherwise. Fill the frontmatter plus **Context & goal**,
**Acceptance criteria**, **How to verify**, and **Out of scope** — now, from the task description,
*before* any code is read. Leave **Affected areas** for the explorer.

**Never clobber an existing `task.md`** — on a fresh worktree there won't be one, but under
`--here` the branch may already carry a contract from an earlier run, and it is what an open PR is
being reviewed against. If it's the same task, extend it in place; if it describes a different
one, stop and ask (supervised) or stop and report (autonomous). The same goes for `plan.md`.

Then start the journal: exclude `journal.jsonl` from git (see the reference), and append the first
`stage` event. From here on, **every** stage transition, agent return, gate decision, and answered
supervised checkpoint (a `decision` event) gets a
line. A journal with gaps is worse than none — it reads as evidence and isn't.

## Stage 3 — Explore (conditional)

Dispatch **explorer** (Agent tool) when the task touches unfamiliar or wide surface area, or when
"which files" is genuinely the open question. Give it the worktree path, the task, and ask for the
Affected-areas content: files and entry points as `path:line`, patterns in play, risks.

Paste its returned summary into `task.md` → **Affected areas**; it is read-only by tool scope and
cannot write the file itself. Journal an `agent` event.

**Skip it** for small, well-scoped tasks — a known file, a doc edit, a one-line fix. A mandatory
round-trip on a trivial change is ceremony, not rigor. Say in the report that you skipped it.

## Stage 4 — Plan

Dispatch **planner** (Agent tool). Give it the **worktree path** — it is the one agent that
writes an artifact, and a bare relative path can land `plan.md` in the parent checkout instead. It
reads `task.md` and writes `plan.md` — ordered steps,
affected areas, test strategy, open questions — and returns the path plus a short rationale. Do
not write the plan yourself; the agent owns that artifact. Read `plan.md` when it returns: you
need it to brief the implementer and to run the checkpoint. Set `status: planned`, journal the
`agent` and `stage` events.

**Supervised checkpoint.** Show the plan and the branch/worktree, and ask to proceed
(AskUserQuestion). This is the cheap moment to redirect the approach or fix a wrong branch name.
Journal the answer as a `decision` event. **Autonomous:** skip; continue to stage 5.

## Stage 5 — Implement

Dispatch **implementer** (Agent tool) against the approved `plan.md`. Give it the worktree path
and point it at `plan.md` and `task.md` — not at a restatement of the plan from your context. It
returns a change summary and commit refs; journal them and set `status: implementing`.

**Decide who commits, and say so in the dispatch.** The implementer's contract is that it commits
*only when asked*, so silence leaves the change uncommitted and stages 7 and 8 each assume
differently. Pick one and be explicit:

- **Default — let `gantry:ship` commit at stage 8.** One commit, the target repo's conventions applied
  by the skill that owns them. Tell the implementer **not** to commit or push.
- **Ask the implementer to commit** when the change wants a specific commit *structure* — separable
  concerns that should not be squashed into one "ship" commit, which is also the case that would
  otherwise make `gantry:ship` stop and ask how to split. Give it the commit boundaries, tell it to
  match the repo's existing `git log` style (including whether that style uses trailers), and tell
  it not to push and not to open a PR — stage 8 still owns the outward-facing half.

Either way, tell it explicitly never to stage or commit `journal.jsonl`. Whichever you chose,
stage 7 reads the working tree the same way, so the review is unaffected.

If it reports that a plan step is wrong or impossible, it has done its job. Do **not** improvise a
different design through it: in supervised mode raise it with the user; in autonomous mode
re-dispatch the planner for the affected step, once, and journal that you did.

## Stage 6 — Gate (the hard blocker)

Run `gantry:auto`'s gate script from inside the worktree — one script, one contract, shared:

```bash
bash "$GANTRY/skills/auto/scripts/run_gates.sh"            # supervised
bash "$GANTRY/skills/auto/scripts/run_gates.sh" --strict   # autonomous
```

`$GANTRY` is this skill's plugin root — resolve it from this file's own location, never a hardcoded
path. Exit codes are the contract: `0` green · `1`+ a check failed · `2` the gate couldn't run ·
`3` NO-GATES under `--strict`. Journal a `gate` event with the literal exit code every time.

- **Red (1+), supervised** → stop; show the failing output. The run ends here; set `status: blocked`.
- **Red (1+), autonomous** → re-dispatch the **implementer** with the failure artifacts, then
  re-run the gate. **At most 2 fix attempts**, `attempt` incrementing **in the journal — the
  orchestrator is the only place this count is kept; the hook keeps none.** Still red at the cap →
  stop, write `status: blocked`, report; there is no automatic escalation path. Nothing pushed.
- **Exit 2** → the gate couldn't run (broken invocation or environment). Stop and report in either
  mode; do not spend an autonomous fix attempt on it. **This exemption applies only to the
  orchestrator's own attempt count for *this inline call*.** If `.claude/hooks/readiness-gate.sh`
  is registered, it does not carry this exemption: from the hook's side, `run_gates.sh` exit `2` is
  just another non-zero result, so it blocks the stop the same as exit `1` would (see below). Per
  "when hook and inline disagree, the hook wins" — a hook block on an exit-2 result still stands
  even though the orchestrator's own inline bookkeeping doesn't count it as a fix attempt.
- **NO-GATES, supervised (0)** → continue, but flag it in the report — no enforced checks is a
  weaker guarantee than a green gate.
- **NO-GATES, autonomous (3)** → **stop; do not push.** Unattended, code that ran zero checks must
  not reach a PR. Suggest adding `.claude/gates.sh`.

**Division of ownership, stated once so the two paths cannot contradict each other.**
`.claude/hooks/readiness-gate.sh` runs on `Stop`/`SubagentStop`, but only when **both**
`.claude/gates.sh` exists at the repo root **and** `task.md` says `status: implementing` — a repo
that registers the hook without a `.claude/gates.sh` gets zero enforcement from it, so "the model
cannot bypass it" depends on that file being present. When armed, it re-runs `run_gates.sh` out of
band and **blocks a red result with exit
`2` — at most once per stop.** It holds no state: no attempt counter, no lock, nothing written to
`task.md`. The inline `run_gates.sh` call above is **belt-and-braces**: it gives you the exit code
to journal and reason about *before* the hook fires, and it is the only gate in repos where the
hook is not registered. **The orchestrator owns everything the hook does not** — the retry cap
above, the `status: blocked` transition, and escalation; `stop_hook_active` on a
repeat stop is how the loop terminates without the hook needing a counter of its own. When hook
and inline run disagree, the hook wins, because it is the one the model cannot skip. Do not treat
a green inline run as permission to ship if the hook has blocked.

## Stage 7 — Review

Get an **independent** read of the diff, and **name in the report which reviewer ran**:

1. **`/code-review` (default)** — purpose-built, runs outside the authoring context and verifies
   its own findings. Prefer it whenever it's invocable here.
2. **A review subagent** — if `/code-review` isn't available, dispatch one with the diff and the
   task, for correctness/security/scope findings by severity.
3. **Self-review, last resort** — and **disclose** that it was one.

**Give the reviewer the whole change, not a commit range.** On the stage-5 default the implementer
has committed nothing and `gantry:ship` at stage 8 is what will, so `git diff <base>...HEAD` is
**empty** — and an empty diff comes back "no findings" while reading nothing. Use `git diff <base>`
(base vs the working tree, committed and not) and list untracked files with `git status --short`,
so new files — often the substance of the change — aren't invisible. This is the right invocation
whichever way stage 5 went: it covers committed and uncommitted work alike, so you never have to
remember which mode the run is in.

Supervised: surface findings before the next checkpoint. Address what's clearly worth fixing, via
the implementer, and re-run the gate if a fix could affect it. Autonomous: apply the clear-cut
fixes, note the rest, don't loop on subjective points.

## Stage 8 — Ship

**Invoke `gantry:ship`** — commit, push, PR. It is idempotent, detects its own stage, and matches the
*target repo's* commit conventions. Pass `--no-pr` and `--base <branch>` through when given. Set
`status: shipped` and journal the final `stage` event.

`task.md` and `plan.md` are committed with the change — they are the contract a reviewer reads.
`journal.jsonl` and gate logs stay excluded.

**Supervised checkpoint — before invoking ship.** Gates green, review in hand. Ask once: commit,
push, and open the PR? (AskUserQuestion.) The single gate in front of every outward-facing action,
since ship won't pause once running. Journal the answer as a `decision` event — this is the one
approval a reader of the journal will most want to find. **Autonomous:** skip the ask.

Let ship's own guards handle `gh` missing/unauthenticated and rejected pushes. Relay what it reports.

## Stage 9 — Report

One consolidated summary:

- **Task**, **mode**, **branch**, **worktree path**.
- **Artifacts** — paths to `task.md`, `plan.md`, `journal.jsonl`.
- **Delegation** — which agents ran, and if the explorer was skipped, that it was and why.
- **Gate** — green / red / no-gates, exit code, and for autonomous, how many fix attempts.
- **Review** — who reviewed, key findings, what you did about them.
- **Commit SHA**, **push** status, **PR URL** — or the last stage reached and why it stopped.

Be honest about anything skipped, unverified, or stopped short. A run that halted at a red gate is
a *successful* gate doing its job — report it as such, not as a failure.
