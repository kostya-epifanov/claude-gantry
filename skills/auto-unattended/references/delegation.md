# gantry:auto-unattended — artifacts and the delegation map

Detail behind `SKILL.md`: the artifacts a run writes, who writes which, where work is delegated to
the roster, and the context-hygiene rule that makes the whole thing worth doing. Read this once at
the start of a run.

Flags, the three modes, how a phase is invoked, and gate resolution are **shared with `gantry:auto`**
and documented once, in `skills/auto/references/orchestration.md`. This file does not repeat them.

## Contents

- The artifacts
- The delegation map
- Context hygiene (the reason this skill exists)
- Resolving the roster

The `journal.jsonl` envelope and its four event shapes live in [journal.md](journal.md), so the
protocol is written down once.

## The artifacts

All live at the **root of the task's worktree**.

| Artifact | Written by | Committed? |
|---|---|---|
| `task.md` | `gantry:plan` (Affected areas from the explorer) | **yes** — the contract a reviewer reads |
| `plan.md` | `gantry:plan`, revised by `gantry:grill` | **yes** — what the change was supposed to be |
| `handover.md` | `gantry:handover`, when review defers something | **yes** — what this change deliberately left |
| `journal.jsonl` | the orchestrator, append-only | **no** — a run artifact; excluded via `.git/info/exclude` |
| gate logs | the gate script / the readiness hook | **no** — same exclusion |

The three committed files are the record: what was agreed, what was planned, and what was left.
Together they let a reviewer judge the change without having been in the run.

`task.md`'s shape and the order its sections get filled belong to `gantry:plan`, which owns the
file. This skill does not write it; it invokes the phase that does, and reads it back.

There is deliberately **no central task index.** Such a thing exists to schedule *parallel* tasks;
with one task at a time, `git worktree list` already answers "what's in flight." Do not
reintroduce one.

## The delegation map

You **invoke** each phase skill; the phase **dispatches** its own sub-agent where one is warranted.
Two levels, and they are not interchangeable — the phase is the procedure, the agent is a scoped
pair of eyes inside it.

| Phase | You | It dispatches | Returns (its contract) |
|---|---|---|---|
| plan | `/gantry:plan` | **explorer** (Read/Grep/Glob, Haiku), when the surface warrants it | the artifact paths + a short rationale |
| grill | `/gantry:grill` | **critic** (Read/Grep/Glob, Opus), **always** | findings by severity + the plan path |
| implement | `/gantry:implement` | — | a change summary + the gate's exit code |
| review | `/gantry:review` | **reviewer** (Read/Grep/Glob/Bash, Opus), when `/code-review` is unavailable | findings, what was fixed, what was deferred |
| gate | *(script)* | — | an exit code |

A phase dispatches with the **Agent** tool and a self-contained prompt: the worktree path, which
artifacts to read, and what to return. You never dispatch a phase runner yourself — that is what
would put a tool boundary in front of the writing each phase has to do.

**All handoff is via disk.** Never assume an agent can see anything from your context or another
agent's — that is what lets a run survive a restart, and it is why the phase skills read `task.md`
and `plan.md` as files even when they just wrote them.

Note what the agents contribute and what the skills contribute: **the skill body is the procedure,
identical in every mode; the agent is the tool boundary.** `gantry-explorer` cannot write because
it has no `Write` tool, whatever a prompt says. `gantry-reviewer` cannot commit for the same
reason. Prose cannot enforce that; a tool list can — which is why every agent gantry ships is
read-only, and why the writing stays in the phase skill where you can see it happen.

**The gate is never delegated.** `lib/run_gates.sh` is the hard blocker and it stays one — the
guarantee lives in an exit code, not in an agent's judgement. `gantry:implement` runs it inline;
journal its decision every time. `gantry:review` re-runs it after any fix it makes, and
`gantry:ship` re-runs it in the one case where its review stage changed the tree — same script,
same exit-code contract, never a delegated judgement.

The `Stop`/`SubagentStop` readiness hook is what removes the model's ability to *skip* that script.
It is stateless and blocks at most once per stop; the attempt cap and the re-dispatch on a red gate
stay in the orchestrator. See `docs/ARCHITECTURE.md` § "The readiness hook" for the three things
about it that are easy to get wrong.

### Skipping the explorer

`gantry:plan` dispatches it when the task touches unfamiliar or wide surface area — a subsystem
nobody has read, a change whose blast radius is genuinely unknown, or any task where "which files"
is the actual question. It reads directly when the task is small and well-scoped: a mandatory
round-trip on a one-line fix is ceremony, not rigor. Either way the report says which happened.

## Context hygiene (the reason this skill exists)

The orchestrator **coordinates; it does not do.** Concretely, your own context should end a run
holding: the task, the plan's shape, each phase's summary, the gate verdicts, and the ship result.
It should *not* hold file dumps, full diffs, or raw test logs — if it does, the delegation failed
and the run would have been cheaper typed by hand.

So: never ask an agent to "show me the file"; ask it for the answer. Never paste an agent's raw
material into `task.md` or the journal; paste its summary. Read `plan.md` yourself — you need it to
brief the next phase — and that is the one artifact worth spending orchestrator context on.

## Resolving the roster

gantry ships `gantry-explorer`, `gantry-critic`, `gantry-reviewer`, and `gantry-verifier` with the
plugin, so a run is never blocked on a missing roster.

Resolution is **per role, repo first**, and the *phase* does it: if `$ROOT/.claude/agents/<role>.md`
exists it dispatches `<role>`, otherwise `gantry-<role>`. A repo that has tuned one agent to its
codebase overrides that one and inherits the rest. Say what each role will resolve to before
stage 1, and check it at the end against what the phases reported actually dispatching.

If the files exist but a dispatch fails because the agent type is unknown, that is a
**discoverability** problem, not a reason to improvise: repo-level agents are picked up when the
session starts, so a roster added mid-session needs a restart. Stop and say exactly that. Do not
silently fall back to doing the work inline — an orchestrator whose delegation is optional is an
orchestrator you cannot trust to have delegated.

**Nothing dispatches `gantry-verifier`**: the gate is a script, and its exit code is deliberately
not a model's judgment. It ships for callers who want a scoped, read-only check-runner directly.
