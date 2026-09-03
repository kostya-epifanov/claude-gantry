# gantry driver orchestration reference

Detail behind the two driver skills, `gantry:auto` and `gantry:auto-unattended`: how to read the
arguments, what the modes change, where the checkpoints sit, and how a phase is invoked. Read it
once at the start of a run; the skill bodies carry the phase-by-phase flow.

Both drivers point here rather than duplicating it, so the two cannot drift apart.

## Contents

- The three modes
- Arguments and flags
- Invoking a phase, and where delegation happens
- Checkpoints (`gantry:auto` only)
- Gate resolution
- Reusing worktree and ship
- Failure handling

## The three modes

gantry runs the same seven-phase chain three ways. The phases are identical; what differs is who
is driving and how often it stops.

| | Semi-auto | `gantry:auto` | `gantry:auto-unattended` |
|---|---|---|---|
| Driver | you, typing each phase | this skill | this skill |
| Phases run | in your session | invoked by the driver | invoked by the driver |
| Stops | after every phase | two checkpoints | never |
| Red gate | you decide | stop and report | fix, capped at 2 attempts |
| Open fork | `implement` warns; you decide | **AskUserQuestion**, after plan and after grill | **stop**, journal `escalation`, `blocked` |
| Gate invocation | `run_gates.sh` | `run_gates.sh` | `run_gates.sh --strict` |
| No gates found | continue, flagged | continue, flagged | **refuse to push** |
| PR | ready | ready | **draft** |
| `mode:` in `task.md` | `semi-auto` | `auto` | `unattended` |

Semi-auto has no driver skill — it *is* the phase skills, typed in order:

```
/gantry:worktree → /gantry:plan → /gantry:grill → /gantry:implement → /gantry:review
                 → /gantry:handover (only if something was deferred) → /gantry:ship
```

**The gate is a hard blocker in all three.** Unattended removes the human checkpoints; it never
removes the gate. That is the whole design: model for judgment, script for the guarantee.

### Why unattended is a separate skill, not a flag

It was `--autonomous` in v0.1. A flag that silently removes every checkpoint is too easy to add to
a command you were about to run supervised. Typing `/gantry:auto-unattended` is a deliberate act,
and the name says what you are getting.

## Arguments and flags

`$ARGUMENTS` is one string: the task description with optional flags mixed in. There is no flag
parser — read it yourself. Strip the recognised flags out; what remains, cleaned up, is the task.

| Flag | Effect |
|---|---|
| `--no-pr` | End after push; don't open a PR. Passed through to `gantry:ship`. |
| `--branch <name>` | Use this exact branch name instead of deriving one from the task. |
| `--here` (alias `--on-current`) | Skip worktree creation; run on the branch you're already on. Mutually exclusive with `--branch`. Refuses on the repo default branch or a detached HEAD. |
| `--base <branch>` | Override the PR base branch. Passed through to `gantry:ship` (and its detector). |

Everything not a flag is the task. If nothing remains after stripping them, stop and ask what the
task is — except under `gantry:auto-unattended`, where there is nobody to ask: stop and report.

### Deriving the branch name

When `--branch` isn't given, derive one from the task: a short kebab-case slug, prefixed by type
when the task makes it obvious — `feat/` for new capability, `fix/` for a bug, else no prefix.
"add a dark-mode toggle" → `feat/dark-mode-toggle`. Keep it under ~40 chars. `gantry:worktree`
validates it and owns the branch and parent logic from there.

## Invoking a phase, and where delegation happens

A driver does not reimplement a phase — and it does not wrap one in a sub-agent either. It
**invokes the phase skill**, the same command you would type:

> Invoke `/gantry:plan` with the task. It writes `task.md` and `plan.md`, and dispatches the
> explorer itself if the surface needs one.

This is the rule that keeps one procedure in one place:

> **Skills carry the procedure. Agents carry the tool boundary.**

Delegation still happens — one level down, inside each phase, where the sub-job is narrow enough
that a tool boundary means something:

| Phase | Dispatches | For what | Repo override |
|---|---|---|---|
| plan | `gantry-explorer`, when the surface is unfamiliar or wide | locating files, entry points, patterns → *Affected areas* | `.claude/agents/explorer.md` |
| grill | `gantry-critic`, **always, in every mode** | reading `task.md` and `plan.md` cold and returning findings | `.claude/agents/critic.md` |
| implement | — | the phase writes the code; the gate is a script | — |
| review | `gantry-reviewer`, when `/code-review` is unavailable | reading a diff it did not write | `.claude/agents/reviewer.md` |

**Every agent gantry ships is read-only.** `gantry-explorer` and `gantry-critic` have `Read, Grep,
Glob`; `gantry-reviewer` adds `Bash` to read git and run checks.
None can write, however it is prompted — a boundary prose cannot enforce. Writing therefore happens
in the phase skill, in the caller's own context, where it is visible rather than reported.

**Resolution is per role, repo first, independently** — and the *phase* does it, not the driver. A
repo that has tuned one agent to its codebase overrides that one and inherits the rest. A driver's
job is to say, at the end, which agents the phases reported actually dispatching.

**Why a driver still carries `Agent` in `allowed-tools`.** Not to dispatch phases. A skill's
frontmatter *restricts* what is permitted while it is active; it does not grant. So a driver must
permit every tool the phases it invokes need — `Agent` included, or `grill` cannot dispatch its
critic.

If a dispatch fails with an unknown agent type, the repo's roster was added mid-session and needs a
restart. **Do not silently fall back to doing the work inline** — a phase whose delegation is
optional is one you cannot trust to have delegated.

**All handoff is via disk.** Never assume an agent can see your context or another agent's. Give it
paths and let it read them; take back a summary, not the payload.

### Preconditions for unattended — no blocking prompts

`gantry:auto-unattended` runs headless, so there is no human to answer a mid-run question, and one
would hang the run:

- **`gantry:worktree`** asks (AskUserQuestion) when the current branch isn't the base, to confirm
  the parent. Avoid it: start the run **from the base branch**, and pass `--branch` to fix the name
  up front.
- **`gantry:ship`** pauses to ask how to split when it sees several unrelated changes. Keep the task
  single and coherent so the diff is one change.
- **`gantry:plan`** asks when a genuine fork would change the work. Under `unattended` it records
  the fork in *Open questions*, leaves it open, and does **not** mark the plan `planned`. It does
  not take a reading of its own — see below.

If a prompt is unavoidable for a given task, that task isn't a fit for unattended — run it
supervised.

### The one prompt unattended cannot route around

A genuine design fork is the exception to everything above, and it is deliberate. Unattended does
not avoid the question by answering it conservatively; it **stops**:

- `lib/detect_stage.sh` reports `FORKS:open|none|unknown|absent` from `task.md`'s *Open questions*.
  An unchecked box, or a bare bullet with no box, is open.
- Both drivers check it **twice** — after plan, and again after grill, because a critique can open
  a fork that planning never had.
- **Supervised** puts the open forks to the user in one `AskUserQuestion` round at each point.
  Planning is the cheap moment: the same fork found at review has an implementation on top of it.
- **Unattended** journals an `escalation` event, sets `status: blocked`, hands over, and stops.
- `gantry:implement` refuses on `FORKS:open` when `mode:` is `auto` or `unattended`, so the
  guarantee holds even if a driver's own check were skipped. Typed by hand it warns instead — a
  hand-driven run iterates between phases, and a note to yourself should not lock you out.

The reasoning is the same as the gate's. A conservative reading of a fork is still a decision
nobody made, and once it is written into a plan it is indistinguishable from one somebody did. A
blocked run costs a re-run; a wrong assumption costs the work built on it.

## Checkpoints (`gantry:auto` only)

Two, both **AskUserQuestion** so the user can redirect in one step:

1. **After plan and grill.** Show the plan as grilled, the findings that changed it, and the
   branch and worktree that were created. "Proceed with this plan?" This is also the moment to
   catch a wrong branch name — cheap to recreate now, before any edits.
2. **After review, before anything outward-facing.** The gate is green and the review is in hand.
   "Commit, push, and open the PR?" One gate in front of every side effect, since `gantry:ship`
   won't pause once invoked.

No checkpoint between implement and gate — the gate is the check there, and it is automatic. There
is deliberately no checkpoint after grill on its own: grill's whole job is to make the plan worth
approving, so the approval belongs after it, not either side of it.

## Gate resolution

`gantry:implement` owns the gate now; a driver does not run it directly. What the drivers still
own is the **mode**, which decides strictness — and that reaches `implement` through `task.md`'s
`mode:` field, not through the conversation.

The script, not any skill, decides what "the gates" are:

1. If the target repo has `.claude/gates.sh`, that file *is* the gate — its exit code is used as
   given, except that a `2` or a `3` is reported as `1` (see the exit codes below). This is how a
   repo reproduces its real CI and overrides any heuristic.
2. Otherwise it auto-detects checks (JS lint/typecheck/build/test, Dart/Flutter analyze+test,
   Python ruff/pytest, Cargo, Go, a Makefile `test` target) at the repo root **and** in each
   subproject a bounded, depth-limited scan finds. A monorepo whose manifests live in subdirs is
   covered, not missed.
3. If it detects nothing, it prints `NO-GATES` — exit 0, or exit 3 under `--strict`.

Exit codes: `0` green · `1`+ a check failed · `2` usage/not-a-repo · `3` `NO-GATES` under
`--strict`. **`2` and `3` mean run_gates' own conditions, never a check's.** A check that exits
`2` or `3` on its own — pytest on a collection error, eslint on a fatal config, a repo gate that
uses those codes — is reported as `1`, so a genuinely red tree is never read as a broken
environment and waved past the fix loop.

`NO-GATES` is handled differently by mode, on purpose. **Supervised** continues but must say
plainly that the run had no enforced checks — a weaker guarantee than green — and suggest adding
`.claude/gates.sh`. **Unattended** stops and refuses to push: with no human watching, a push of
code that ran zero checks is exactly what the gate exists to prevent.

### Hook vs. inline

A repo may also register gantry's `readiness-gate.sh` on `Stop`/`SubagentStop`. Where it is
registered, **the hook is the blocker** — but only when **both** `.claude/gates.sh` exists at the
repo root **and** `task.md` says `status: implementing`. A repo that registers the hook without a
`.claude/gates.sh` gets no enforcement from it.

When armed, it runs the same `run_gates.sh` out of band, and a red result blocks the stop with exit
`2` — the model cannot decline it. Note the asymmetry: the hook does **not** carry the inline call's
exemption for the gate's own exit `2`, so a gate that could not run blocks the stop rather than
being reported as an environment problem.

The inline run inside `implement` is belt-and-braces where a hook is registered — it gives an exit
code to journal and reason about before the hook fires — and it is the **only** gate where none is.
**When the two disagree, the hook wins.** Never treat a green inline run as permission to ship past
a hook that blocked.

The hook holds no state and blocks a given stop at most once; `stop_hook_active` is the whole of
its loop termination. **The retry cap, the `status: blocked` transition, and escalation live in the
orchestrator**, exactly as they do in a repo with no hook at all.

`lib/detect_stage.sh` reports `HOOK:conditions-met` or `HOOK:conditions-unmet` so a run can say
which it was. Read the value for exactly what it says: the hook's **firing conditions** — a
`.claude/gates.sh` at the repo root and `status: implementing` — and not whether the hook is
registered, which the detector cannot see and does not claim. `conditions-met` therefore means
"this would have been enforced if the hook is installed", which is one step short of "this was
enforced".

That gap is the reason the line is worth reporting at all. A report that implies enforcement it did
not have is worse than one that admits self-policing.

**A grep of `settings.json` will not tell you whether the hook is registered.** gantry registers it
at *plugin* level, through the plugin's own `hooks/hooks.json`, so a config search finds nothing and
proves nothing in either direction. `/plugin` is what shows whether gantry is installed and enabled.

The hook's audit log at `.claude/artifacts/gate-hook.log` answers a different question — whether it
*ran* — and only once the repo has opted in. With `task.md` and `.claude/gates.sh` both present,
every invocation appends a line, fire or skip. Without them the hook exits before creating the
directory, so an absent log is what a correctly registered hook produces, not evidence against one.

## Reusing worktree and ship

The drivers orchestrate existing skills rather than duplicating them:

- **`gantry:worktree`** for the branch, the worktree, and the parent fetch. Don't reimplement any of
  it. The exception is `--here`, which skips it and runs on the current branch — guarding against
  the default branch and a detached HEAD first.
- **`gantry:ship`** for commit → push → PR. It is idempotent, detects its own stage, and
  matches the *target repo's* commit conventions — which is why the drivers don't hardcode gantry's
  own no-trailer style, since they run in arbitrary repos. Pass `--no-pr`, `--base`, and (unattended
  only) `--draft` through.

  **Pass no review flag.** Ship reviews only when asked — `--review` and `--review-fix` are the
  only way a reviewer runs from it — and the chain has already run `/gantry:review` as its own
  phase by then. A second pass would review the same diff twice, and under `--review-fix` would
  reopen and apply findings that phase deliberately deferred to `handover.md`. This holds in every
  mode.

No skill in gantry carries `disable-model-invocation`: a gated skill cannot be invoked by an agent
at all, only by a human typing the command, which would make the whole pipeline undelegatable. See
`docs/ARCHITECTURE.md` § "Why no skill is model-gated" for the tradeoff that buys.

## Failure handling

Lean on the sub-skills' own guards rather than re-checking everything:

- **Not a git repo / worktree can't be created** → `gantry:worktree` reports it; stop and relay.
- **No `plan.md`** → `gantry:implement` refuses. That is correct; don't route around it.
- **`gh` missing or unauthenticated** → `gantry:ship` still commits and pushes, then prints the
  manual `gh pr create` command. Relay it; not fatal.
- **Push rejected (remote moved)** → `gantry:ship` stops rather than force-pushing. Relay; the user
  integrates and re-runs.
- **Branch is the repo default** → without `--here`, the drivers work on a fresh branch via
  worktree, so this shouldn't arise. With `--here`, check up front; ship's `on-default` guard is
  the backstop.
