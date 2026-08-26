# gantry:factory — the task contract and the delegation map

Detail behind `SKILL.md`: the artifacts a run writes, who writes which, how work is dispatched
to the roster, and the context-hygiene rule that makes the whole thing worth doing. Read this
once at the start of a run.

Flags, the two modes, checkpoint placement, and gate resolution are **identical to `gantry:auto`**
and documented once, in `skills/auto/references/orchestration.md`. This file
does not repeat them.

## Contents

- The four artifacts
- `task.md` — what to fill, and when
- `journal.jsonl` — the append protocol
- The delegation map
- Context hygiene (the reason this skill exists)
- When the roster is missing

## The four artifacts

All live at the **root of the task's worktree**.

| Artifact | Written by | Committed? |
|---|---|---|
| `task.md` | the orchestrator (Affected areas from explorer) | **yes** — it is the contract a reviewer reads |
| `plan.md` | the **planner** sub-agent, and only it | **yes** — the thing a human skims before implementation |
| `journal.jsonl` | the orchestrator, append-only | **no** — a run artifact; excluded via `.git/info/exclude` |
| gate logs | the gate script / verifier | **no** — same exclusion |

There is deliberately **no central task index**. Such a thing exists to schedule *parallel*
tasks; with one supervised task at a time, `git worktree list` already answers "what's in
flight." Do not reintroduce one.

## `task.md` — what to fill, and when

Resolution order: the repo's `docs/templates/task.md` when it exists, else the plugin's own
`$GANTRY/skills/factory/templates/task.md`, else the inline skeleton below.

Copy the repo's `docs/templates/task.md` when it exists. When it does not — `gantry:factory` runs
in other repos too — write this skeleton instead:

```markdown
---
id: <yyyy-mm-dd>-<slug>
title: <one line>
project: <repo name>
branch: <branch>
mode: supervised | autonomous
status: draft
---

## Context & goal
## Acceptance criteria
## How to verify
## Out of scope
## Affected areas
## Open questions
```

Fill it in two passes, not one:

- **At stage 2 (contract), before any code is read:** frontmatter, Context & goal, Acceptance
  criteria, How to verify, Out of scope. These come from the task description and from you —
  they are the statement of intent the rest of the run is judged against. Writing them *before*
  exploring is the point: it stops the plan from quietly redefining the task.
- **After the explorer returns (stage 3):** Affected areas, verbatim from its summary. The
  explorer is read-only by tool scope and physically cannot write the file; you paste what it
  returns.

`status` tracks the run: `draft` → `planned` (plan.md exists) → `implementing` → `blocked`
(gate red, attempts exhausted) or `shipped` (PR open). Update it as you transition; it is the
one field a human scanning several worktrees actually reads.

Keep acceptance criteria **checkable**. "The form validates input" is a criterion; "the form
works well" is not. The gate proves the automated ones; the human-only list in the verify block
is what you hand the reviewer.

## `journal.jsonl` — the append protocol

One JSON object per line, appended with `>>`, never rewritten. Full event shapes live in the
repo's `docs/templates/journal.md`; the envelope is `ts` (ISO-8601 UTC) + `task` (the frontmatter
`id`) + `event`, and the three shapes are `stage`, `agent`, and `gate`.

Append a line at:

- **every stage transition** — `contract`, `explore`, `plan`, `implement`, `gate`, `review`, `ship`;
- **every sub-agent return** — its name, `result`, its one-or-two-sentence summary, artifact paths;
- **every gate decision** — result, literal exit code, attempt number, artifact paths;
- **every supervised checkpoint the user answers** — a `decision` event: the question and the
  answer, in one line each. The human's input is the part of a supervised run least recoverable
  from anything else, so a journal that omits it is missing the thing an auditor most wants.

Practical form, with `jq` doing the escaping **and the timestamp**:

```bash
jq -nc '{ts:(now|todate),task:"2026-08-16-contact-form",event:"stage",
         from:"plan",to:"implement",mode:"supervised"}' >> journal.jsonl
```

**Use jq's `now|todate`, not a `$(date -u …)` command substitution.** `now|todate` emits exactly
the envelope's format (`2026-08-16T09:41:07Z`, ISO-8601 UTC, second precision) with no subshell.
This is not a style preference: `factory` always runs inside a worktree (stage 1), and a
worktree-isolated session refuses a command that combines command substitution with a redirect —
*"too complex to verify that it stays inside the worktree"* — so the `$(date …)` form fails on
every run, including the autonomous ones with no human to improvise around it.

Prefer literal values inside the filter, as above. When a value must come from a shell variable,
`--arg` still works — but note it always produces a **string**: the first line of a run has
`"from": null`, which needs `--argjson from null`. `--arg from null` writes the string `"null"`,
and a consumer looking for the run's start with `.from == null` never matches it. Writing `from:null`
directly in the filter, as above, sidesteps this entirely.

If `jq` is not installed, a `printf` of a hand-written line is fine — the file is a convention,
not a schema-validated store. What is **not** fine is skipping the append because the run is
going well: the journal's value is that it is complete.

Exclude the run artifacts once, early, so they never reach the diff — **both** the journal and the
gate logs. Gate output goes under `.claude/artifacts/`; without this, a failed autonomous run's
captured logs get swept into the commit by `gantry:ship`, which is exactly the noise the exclusion
exists to prevent:

Same constraint as the journal append — no command substitution feeding a redirect — so do it as
two plain commands rather than one loop. Check first:

```bash
git check-ignore -v journal.jsonl .claude/artifacts/
```

and if either is unmatched, append them to the **main** repo's exclude file (worktrees share it),
naming the path literally:

```bash
printf '%s\n' 'journal.jsonl' '.claude/artifacts/' >> /path/to/main-repo/.git/info/exclude
```

That write can be denied by the sandbox (`Operation not permitted`) — `.claude/` paths often are.
Retry it unsandboxed; do not skip the exclusion, or `gantry:ship` sweeps the journal into the commit.

## The delegation map

| Stage | Agent | Reads | Returns (its contract) |
|---|---|---|---|
| explore | **explorer** (Read/Grep/Glob, Haiku) | the repo | a paragraph: files + entry points (`path:line`), patterns, risks → goes into Affected areas |
| plan | **planner** (read-only + write `plan.md`, Opus) | `task.md` | the plan path + a short rationale; the plan itself is on disk |
| implement | **implementer** (Read/Write/Edit/Bash, Sonnet) | `plan.md`, `task.md` | a change summary + commit refs |
| gate | *(script)* | — | exit code — see below |

Dispatch with the **Agent** tool, one agent per stage, each with a self-contained prompt: the
task, the worktree path, which artifact to read, and what to return. Never assume an agent can
see anything from your context or another agent's — **all handoff is via disk.** That is what
lets a run survive a restart.

**The gate is never delegated.** `scripts/run_gates.sh` in `gantry:auto` is the hard blocker, and
it stays one — the guarantee lives in an exit code, not in an agent's judgement. Run the script
inline and journal its decision.

The `Stop`/`SubagentStop` readiness hook that removes the model's ability to *skip* that script
is live (`.claude/hooks/readiness-gate.sh`). It is stateless and blocks at most once per stop;
the attempt cap and the re-dispatch on a red gate stay here, in stage 6. See
`docs/ARCHITECTURE.md` § "The readiness hook" for the three things about it that are easy to get
wrong.

### Skipping the explorer

Dispatch it when the task touches unfamiliar or wide surface area — a subsystem you have not
read, a change whose blast radius is genuinely unknown, or any task where "which files" is the
actual question. Skip it when the task is small and already well-scoped (a known file, a doc
edit, a one-line fix): a mandatory round-trip on a trivial change is ceremony, not rigor. When
you skip it, say so in the report and leave Affected areas for the planner to ground.

## Context hygiene (the reason this skill exists)

The orchestrator **coordinates; it does not do.** Concretely, in your own context you should end
a run holding: the task, the plan's shape, each agent's summary, the gate verdict, and the ship
result. You should *not* be holding file dumps, full diffs, or raw test logs — if you are, the
delegation failed and the run would have been cheaper as `/gantry:auto`.

So: never ask an agent to "show me the file"; ask it for the answer. Never paste an agent's raw
material into `task.md` or the journal; paste its summary. Read `plan.md` yourself (you need it
to brief the implementer and to run the checkpoint) — that is the one artifact worth spending
orchestrator context on.

## Resolving the roster

gantry ships `gantry-explorer`, `gantry-planner`, and `gantry-implementer` with the plugin, so a
run is never blocked on a missing roster. Resolution is **per role, repo first**: if
`$ROOT/.claude/agents/<role>.md` exists, dispatch `<role>`; otherwise dispatch `gantry-<role>`. A
repo that has tuned one agent to its codebase overrides that one and inherits the rest. Say which
set each role resolved to before stage 1.

If the files exist but a dispatch fails because the agent type is unknown, that is a
**discoverability** problem, not a reason to improvise: repo-level agents are picked up when the
session starts, so a roster added mid-session needs a restart. Stop and say exactly that. Do not
silently fall back to doing the work inline — an orchestrator whose delegation is optional is an
orchestrator you cannot trust to have delegated.
