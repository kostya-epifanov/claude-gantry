---
name: qa
description: Run the task's e2e scenarios against the built app and report what happened, scenario by scenario — the repo supplies the driver (.claude/agents/qa.md) and the environment (.claude/qa-env.sh), gantry supplies the contract. Writes qa.md at the worktree root, which gantry:ship quotes into the PR body; a repo with no qa agent gets one line and the chain continues. Reported, never enforced. Read-only unless --fix. Use when the user types "/gantry:qa", or asks to run the e2e scenarios, tap through the feature, or check that the app actually works.
argument-hint: [--fix]
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Skill, Agent, AskUserQuestion, SendMessage
---

# gantry:qa

Run the product, not the diff. The gate proves the tree with an exit code and the review reads the
change; neither one taps through the feature. This phase does — against the app the repo builds,
with the driver the repo chose — and writes down, per scenario, what it saw.

**Reported, never enforced.** The verdict blocks nothing on its own, in every mode, the same rule
as `lib/gate_coverage.sh`. What blocks is what the repo put in `.claude/gates.sh`. "The feature
does not work" and "nobody could check whether it works" are different facts and must never read
the same; this skill's whole output is keeping them apart.

**The method's line, exactly.** The environment is a script (`.claude/qa-env.sh`: build, boot,
install, log in — deterministic, so it has an exit code). The exploration is judgment (the repo's
`qa` agent, driving the app from a goal). The record is a file (`qa.md`). And the loop closes when
judgment leaves a script behind: a flow file the agent wrote joins the repo's suite, and from the
next task on that scenario is enforced by the gate, with no model in the loop.

**Read-only by default.** With no `--fix`, this skill makes **no change to the code**. It still
writes `qa.md`, always, and `handover.md` when it defers something — gantry's own bookkeeping,
not the change. `--fix` licenses it to repair an in-scope failure, and then the gate re-runs.

## The repo opts in with two files, and gantry ships no default

- **`.claude/agents/qa.md`** — the driver. Its `tools:` line carries whatever drives that stack
  (`Read, Bash` plus the Maestro MCP tools for a Flutter app; the Playwright MCP tools for a web
  app). That line is the capability boundary, as for every roster agent. **There is no
  `gantry-qa`.** A default agent would have to pick a stack, which is the one thing a published
  plugin cannot do; a reviewer must not have a tool that taps real UI, and a CLI repo has nothing
  to drive. Absent is the normal case and is never a warning — the same stance as the
  `gantry-profile` contract (`docs/ARCHITECTURE.md` § *The one external hook*).
- **`.claude/qa-env.sh`** — the environment. The gate's exit-code shape: `0` the app is up and
  reachable · `1`+ setup failed (the build broke, the device is missing) · `2` the script itself
  could not run. It is where `setup: { use_profile: true }` in the task's e2e block gets applied.
  `examples/qa-env.sh` is a starter.

An agent with no `qa-env.sh` beside it is a **configuration error this phase names**: an agent
dispatched against an app that may not be running produces findings nobody can trust, so it is
treated as `unrunnable`, never as a pass and never as a fail.

## Steps

### 1. Detect the stage

`$GANTRY` is this skill's plugin root — resolve it from this file's own location rather than
hardcoding a path.

```bash
bash "$GANTRY/lib/detect_stage.sh"
```

- `PHASE:not-a-repo` → stop.
- `STATUS:implementing` → **stop, in every mode.** The gate has not gone green on this tree, so
  there is no built app worth testing yet. Name `/gantry:implement`.
- `TASK:absent` / `TASK:inherited` → there is no contract and so no scenarios to run or derive —
  an inherited `task.md` is the *previous* task's. Say so and **stop**; write nothing.
- `STATUS:planned` / `critiqued` / `grilled` with a clean tree → nothing has been built. Say so, name
  `NEXT`, stop.

Then read four more lines, which decide the rest of the run:

- **`QA_ROLE:`** — `.claude/agents/qa.md`. `absent` → step 2 writes the file and stops.
- **`QA_ENV:`** — `.claude/qa-env.sh`. `absent` with a role present → the configuration error above.
- **`E2E:`** — whether `task.md` declares scenarios. `none` or `absent` → step 3 derives them.
- **`QA:`** — an existing `qa.md` is a *previous* run's and is **overwritten** in step 7.

Read `task.md`'s `mode:` too. It decides whether this run may ask (`semi-auto`, `auto`) or must
decide for itself (`unattended`), and which gate strictness `--fix` uses — exactly as `review`
reads it. If the frontmatter names a `lead:`, every question below goes to the lead as a `fork`,
following `$GANTRY/skills/auto/references/lead.md`.

`<task-id>` below is `task.md`'s `id:`. Evidence lands under `.claude/artifacts/qa/<task-id>/`;
keep it out of git before anything is written there, together with the file this run will write:

```bash
bash "$GANTRY/lib/ensure_excluded.sh" /task.md /plan.md /handover.md /review.md /qa.md .claude/artifacts/
```

### 2. Resolve the role

**`QA_ROLE:absent`** → this repo has not opted in. Write `qa.md` with `outcome: no-agent` (step 7),
report it in one line, and stop. Not a warning: most repos have nothing to drive, and the chain
continues through `ship`, which says in the PR body that the declared scenarios were not run.

**`QA_ROLE:present`, `QA_ENV:absent`** → write `qa.md` with `outcome: unrunnable` and the reason
*"`.claude/agents/qa.md` exists with no `.claude/qa-env.sh` beside it"*. Stop. Name the fix: copy
`examples/qa-env.sh` from the plugin and fill it in.

Both present → read the agent file's frontmatter and **record its `tools:` line** in `qa.md`. That
line is what the reader needs to weigh the verdict: a driver with no screenshot tool observed less
than one with it, and a `qa.md` that does not say which ran reports more than it knows.

### 3. The scenarios

Read `task.md`'s `verification.automated.e2e.scenarios`. Each entry is a **goal**, optionally with
`steps`; empty `steps` means you derive them from the goal and the acceptance criteria. Mark each
`declared`.

On `E2E:none` or `E2E:absent`, **derive two to four scenarios** from the acceptance criteria the
diff touches — not everything the app does. Read the diff (`git diff <BASE>` plus
`git status --short`, as `review` does) to see which criteria this change can have affected, and
write one scenario per criterion it can. Mark each `derived`. A declared scenario and a derived one
are different evidence, and `qa.md` says which each was.

Nothing to derive — a change with no user-reachable surface, a docs or build change — → write
`qa.md` with `outcome: no-scenarios` and why, and stop **before** booting anything. A device boot
is the expensive step; do not pay it for a run with nothing to look at.

Write the list to `.claude/artifacts/qa/<task-id>/scenarios.md` — one heading per scenario with
its goal, its steps if any, the acceptance criterion it maps to, and `declared` or `derived`. That
file is what the agent reads; **all handoff is via disk.**

### 4. The environment is a script

```bash
bash .claude/qa-env.sh .claude/artifacts/qa/<task-id>
```

Run it from `ROOT`, with the Bash tool. The one argument is the evidence directory, so the script
can leave its own logs there; a script may ignore it. Capture the transcript to
`.claude/artifacts/qa/<task-id>/env.log`. A boot can be slow — if the repo's script is known to
take longer than the tool's cap, run it with `run_in_background` and wait for the completion
notification rather than polling.

- `0` → the app is up. Go on.
- `1`+ → **`unrunnable`**. Write `qa.md` with `outcome: unrunnable`, the exit code, and the last
  lines of `env.log` as the reason. Stop. Nothing failed QA; nobody could run it.
- `2` → the same, reported as *the script could not run* rather than *setup failed*.

Like the gate's own exit `2`, `unrunnable` is a distinct line in the report, never folded into a
fail.

### 5. Dispatch the repo's `qa` agent

**Agent tool**, agent type `qa` — the repo's file, never a gantry one. If the dispatch fails with
an unknown agent type, the roster was added mid-session and needs a restart: stop and say exactly
that; do not drive the app yourself. Give it, as paths:

- the worktree root;
- `task.md`;
- `.claude/artifacts/qa/<task-id>/scenarios.md`;
- `.claude/artifacts/qa/<task-id>/` as the place to save screenshots and any logs.

Ask it to return, **per scenario**: `pass`, `fail` or `could-not-reach`, one concrete observation
(what it saw, not what it expected), and the paths of the evidence it saved. Then, separately: the
paths of any **flow files** it wrote while reproducing a scenario (a Maestro YAML, a Playwright
spec — whatever its driver writes), or that it wrote none. Take back that summary, not the
transcript: screenshots and UI trees are exactly what the agent's context exists to hold instead
of yours.

`could-not-reach` means the agent could not get the app into the scenario's starting state — not
that the scenario failed. Keep the three apart in `qa.md`; they call for different next actions.

### 6. Triage — `review`'s own steps, not a second copy

A `fail` is a finding, and findings go through the procedure `gantry:review` already owns —
**verify** (its step 3), **triage** against `task.md`'s *Out of scope* (step 4), **hand over** what
is deferred (step 6). Apply those steps as written there; this skill does not restate them, so the
two cannot drift. In this phase's terms:

- **Verify**: open the evidence. A `fail` whose screenshot shows the expected state is the agent
  misreading, and is dropped and counted, not listed. Name the acceptance criterion each surviving
  failure falsifies — a failure that falsifies none is a finding about the app, not about this task.
- **Address now**: the failure is in code this change introduced and the criterion is this task's.
- **Defer**: a pre-existing defect the scenario merely reached, anything *Out of scope*, anything
  that needs its own plan. **Never fix these.** Invoke `gantry:handover` for them.
- **Drop**: the agent's misread, or a scenario that turned out not to map to any criterion.

Where the call is honestly ambiguous and the mode allows a question, ask — one `AskUserQuestion`
round, or the lead. Under `mode: unattended`, defer rather than expand.

**With `--fix`**, repair what you kept, then **re-run the gate** — a fix made after the gate went
green is unproven code:

```bash
bash "$GANTRY/lib/run_gates.sh"            # semi-auto, auto
bash "$GANTRY/lib/run_gates.sh" --strict   # unattended
```

Same exit-code contract as `/gantry:implement`: `0` green · `1`+ red · `2` could not run · `3`
`NO-GATES` under `--strict`. Red means the fix broke something: capped at 2 attempts unattended,
stop and report supervised. Then, **once**, re-run step 4 and re-dispatch step 5 for the scenarios
that failed — the fix changed the app, so the old verdict describes a binary that no longer exists.
Record both verdicts. A fix the re-run did not confirm stays `fail` in the file, with the fix noted.

**The fix landed after review.** `/gantry:review` ran on the tree before this phase changed it.
Say so in `qa.md`'s `applied:` line and in the report; the gate proved the fix, the reviewer did
not see it, and the reader should know which.

**Without `--fix`**, edit nothing. Report the address-now failures as what *would* be fixed and
name `/gantry:qa --fix`.

**Blocking.** The one case: a verified `fail` that falsifies a stated acceptance criterion and was
not repaired (no `--fix`, or the fix did not hold). Then set `task.md` to `status: blocked`, hand
over, and say so — the change does not do what its own contract says, and that is a fact about the
task rather than an enforcement of the verdict. A `fail` outside the criteria is deferred, not
blocking. `could-not-reach` and `unrunnable` never block anything.

### 6b. The loop: a flow file joins the suite

If step 5 reported flow files, they are the part worth the rest of this phase: once the repo's
`.claude/gates.sh` runs them, that scenario is enforced from the next task on, by the hook, with no
model in the loop. Decide what happens to them, by mode:

- **`semi-auto`, `auto`** → **ask**, one `AskUserQuestion` (a `fork` to the lead when there is
  one): *Keep* the files in the tree, so `gantry:ship` commits them with the change, or *Remove*
  them. Name the paths and say plainly that nothing runs them yet. Do not offer `stop`.
- **`unattended`** → keep them in the tree, say so in the report, and add a `handover.md` item
  naming each file and the next action: wire it into `.claude/gates.sh`. The driver journals it. A
  flow nobody has wired is harmless in a draft PR; a flow silently deleted is the loop not closing.

### 7. Write `qa.md`

At the worktree root, with the Write tool, **overwriting** whatever is there — a file left by an
earlier run describes a tree that has since moved. Written on every run that passed step 1,
whatever the outcome, so that "qa ran and found no agent" and "qa never ran" are different facts
on disk. The shape:

```
# QA
branch: <branch>
task: <task-id>
outcome: exercised | unrunnable | no-agent | no-scenarios
reason: <one line, on anything but exercised>
agent: .claude/agents/qa.md
tools: <the agent file's tools: line, verbatim>
env: .claude/qa-env.sh exit=<n>
scenarios: declared=<n> derived=<n>
verdicts: pass=<n> fail=<n> could-not-reach=<n>

## Scenarios
- <name> (declared|derived) — <pass|fail|could-not-reach>. <observation>. Evidence: <paths>
- …

## Flow files
- <path> — kept | removed | kept, not yet wired (unattended)
None.                      # when the agent wrote none

## Address now
- <scenario> — <criterion it falsifies>. <what is wrong>.
None.
```

`lib/detect_stage.sh` reads the `outcome:` line as `QA:`; `gantry:ship` quotes the `## Scenarios`
lines under `## Exercised by this run` when the outcome is `exercised`, and on any other outcome
puts the task's declared scenarios under `## Not proven by this run` with the `reason:` line. Keep
`outcome:` to exactly those four values — anything else reads as `unknown`, which ship treats as
not exercised.

With `--fix`, append one line, last, after the gate's final run:

```
applied: <ISO-8601 UTC date> gate=<exit> after-review=yes
```

### 8. Status

Leave `task.md`'s `status:` alone unless step 6 blocked. This phase is not a state on the chain's
machine — a `reviewed` task is still `reviewed` after it, and `lib/detect_stage.sh` still names
`/gantry:ship` next. The record is `qa.md`, not the status.

## Report

The outcome, first: `exercised`, `unrunnable` (with the env exit code and the reason), `no-agent`,
or `no-scenarios`. Then, for an exercised run, one line per scenario with its verdict and whether
it was declared or derived — and the agent's `tools:` line, so the reader knows what observed it.

How many failures were verified, addressed, deferred and dropped, as `review` reports its tallies.
Whether `--fix` was given; without it, what would have been fixed; with it, the gate's exit code,
the re-run's verdicts, and that the fix landed after review. Whether the task was blocked and on
which criterion.

Any flow files, where they are, and what was decided about them — kept, removed, or kept and
handed over. The `qa.md` path, the evidence directory, and the `handover.md` path if one was
written. End by naming the next command: `/gantry:ship`.
