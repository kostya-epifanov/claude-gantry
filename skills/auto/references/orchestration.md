# gantry driver orchestration reference

Detail behind the two driver skills, `gantry:auto` and `gantry:auto-unattended`: how to read the
arguments, what the modes change, where the checkpoints sit, and how a phase is invoked. Read it
once at the start of a run; the skill bodies carry the phase-by-phase flow.

Both drivers point here rather than duplicating it, so the two cannot drift apart.

## Contents

- The three modes
- Arguments and flags
- Invoking a phase, and where delegation happens
- Headless phases
- Checkpoints (`gantry:auto` only)
- Gate resolution
- Reusing worktree and ship
- Failure handling

## The three modes

gantry runs the same chain three ways. A phase that appears in two of them is the *same* phase, not
a variant of it — that is the property the whole design rests on. What differs is who drives, how
often it stops, and one phase: `grill` is human-only, so `gantry:auto-unattended` runs
`plan-critique` and no grill at all.

| | Semi-auto | `gantry:auto` | `gantry:auto-unattended` |
|---|---|---|---|
| Driver | you, typing each phase | this skill | this skill |
| Phases run | in your session | invoked by the driver | invoked by the driver |
| Review runs | in your session | **headless child** | **headless child** |
| Stops | after every phase | a grill conversation, then one checkpoint | never |
| Red gate | you decide | stop and report | fix, capped at 2 attempts |
| Open fork | `implement` warns; you decide | settled inside `grill`, in priced options | **stop**, journal `escalation`, `blocked` |
| Gate invocation | `run_gates.sh` | `run_gates.sh` | `run_gates.sh --strict` |
| No gates found | continue, flagged | continue, flagged | **refuse to push** |
| PR | ready | ready | **draft** |
| `mode:` in `task.md` | `semi-auto` | `auto` | `unattended` |

Semi-auto has no driver skill — it *is* the phase skills, typed in order:

```
/gantry:worktree → /gantry:plan → /gantry:grill → /gantry:implement → /gantry:review --fix
                 → /gantry:handover (only if something was deferred) → /gantry:ship
```

`/gantry:grill` chains `/gantry:plan-critique` itself when the status is `planned`, so typing grill
by hand runs the cold critique too — which is why the line above names one command where the chain
has two phases. Type `/gantry:plan-critique` separately only to re-run a critique.

**The gate is a hard blocker in all three.** Unattended removes the human checkpoints; it never
removes the gate. That is the whole design: model for judgment, script for the guarantee.

`gantry:auto --lead <session>` is not a fourth mode. It is supervised `gantry:auto` with a different
answerer: every question goes to a lead session by message rather than to a dialog, and every row
above still reads `gantry:auto` — the gate is still a hard blocker, a red gate still stops, the PR
is still ready. See *Lead mode* below.

### Why unattended is a separate skill, not a flag

It was `--autonomous` in v0.1. A flag that silently removes every checkpoint is too easy to add to
a command you were about to run supervised. Typing `/gantry:auto-unattended` is a deliberate act,
and the name says what you are getting.

## Arguments and flags

`$ARGUMENTS` is one string: the task description with optional flags mixed in. There is no flag
parser for the flags themselves — read them yourself. The two values that have to be exact, the
tracker id and an explicit `--branch`, come from `lib/task_id.sh` (see *Deriving the branch name*
below). Strip the recognised flags out; what remains, cleaned up, is the task.

| Flag | Effect |
|---|---|
| `--no-pr` | End after push; don't open a PR. Passed through to `gantry:ship`. |
| `--branch <name>` | Use this exact branch name instead of deriving one from the task. |
| `--task <id>` | The tracker id for this run (`BASE-71`, `GH-71`, a Jira key). Wins over an id found in the task text or a tracker URL. Passed through to `gantry:plan`. |
| `--here` (alias `--on-current`) | Skip worktree creation; run on the branch you're already on. Mutually exclusive with `--branch`. Refuses on the repo default branch or a detached HEAD. |
| `--base <branch>` | Override the PR base branch. Passed through to `gantry:ship` (and its detector). |
| `--lead <session>` | **`gantry:auto` only.** Every question the run would ask in a dialog goes to that lead session by `SendMessage`, and only a narrow reply vocabulary is accepted. Protocol: `references/lead.md`. `gantry:auto-unattended` refuses the flag. |
| `--review-model <alias>` | The model the review children run on, passed to the launcher as `--model`. Absent, the child inherits the user's default. `sonnet` is a cost-neutral choice for a review. `gantry:ship` takes it too. |
| `--review-effort <level>` | The effort level for the review children, passed as `--effort`. Absent, neither flag is passed and the child inherits. |

Everything not a flag is the task. If nothing remains after stripping them, stop and ask what the
task is — except under `gantry:auto-unattended`, where there is nobody to ask: stop and report.

### Deriving the branch name

The driver reads its flags as prose, but the two values that have to be exact — a tracker id and
an explicit `--branch` — come from a script. First exclude the artifacts directory, then write the
**whole argument string, verbatim**, to a file of your own under it with the Write tool — never by
echoing it on a command line, since a task description may carry quotes, backticks or `$(`, which a
worktree-isolated session refuses and a shell might expand — and run the parser on it:

```bash
bash "$GANTRY/lib/ensure_excluded.sh" .claude/artifacts/
bash "$GANTRY/lib/task_id.sh" --args-file .claude/artifacts/args-<something unique to this run>.txt
```

Name the file per run — the slug you are about to derive, or a timestamp — because several lanes
can start from the same checkout at once, and a shared `args.txt` would hand one lane another's id.

It prints four lines — `ID:`, `SOURCE:`, `BRANCH:`, `TEXT:` — and the header of `lib/task_id.sh`
is the contract. The id comes from, in order: `--task <id>`; an id at the **start** of the task
text (`BASE-71 integrate should update docs`, the drivers' own flags skipped); a tracker URL in the
text (a GitHub issue becomes `GH-<n>`, Linear and Jira links give their key); and, on a re-run
inside a lane, `task.md`'s `id:` — pass `--task-file task.md` for that, under `--here`, and **only
when the detector says `TASK:present`**: an `inherited` file is the previous task's contract, and
its id would title the new PR after the wrong issue. A tracker id is `[A-Z][A-Z0-9_]*-[0-9]+`, kept
exactly as written. `TEXT:` is the string with `--task`, `--branch` and the leading id removed, and
is what you pass on as the task; every other flag is still in it for you to read.

**Value-taking flags go before the task.** `--task` and `--branch` are read as flags only in the
run of flags ahead of the task's first word; from that word on every token is text, so a task
that *mentions* `--branch` or `--task` in prose keeps its words and names nothing. A `--task` or
`--branch` you meant as a flag but typed after the text is still visible in `TEXT:` — move it.

Exit `2` means a leading `--task` or `--branch` that is repeated or has a missing or bad value:
`gantry:auto` asks, and `gantry:auto-unattended` stops and reports.

Then the name:

- **`BRANCH:` is not `-`** → use it verbatim. The rule below does not apply to an explicit name.
- Otherwise derive `<type>` and `<slug>` from `TEXT:` as before: a short kebab-case slug, prefixed
  by type when the task makes it obvious — `feat/` for new capability, `fix/` for a bug, else no
  prefix. "add a dark-mode toggle" → `feat/dark-mode-toggle`.
- **`ID:` is not `-`** → the name is `<type>/<ID>-<slug>` (`<ID>-<slug>` with no type):
  "BASE-71 integrate should update docs" → `feat/BASE-71-integrate-docs`. Keep the whole name under
  ~48 characters by shortening the slug, never the id, and never over the 64 that
  `gantry:worktree` enforces.
- **`ID:` is `-`** → exactly the name you would have derived before: `<type>/<slug>`, under ~40
  characters.

`gantry:worktree` validates the result and owns the branch and parent logic from there. The
worktree path follows the branch, as always: `.claude/worktrees/feat/BASE-71-integrate-docs`.

`ID:` is also the run's task id. Pass it to `/gantry:plan` as `--task <id>`, the same way `--lead`
is passed, so `task.md`'s `id:` is the tracker id and `journal_append.sh --task`, the readiness
hook and the PR title all see the same id as the branch. Under `--here` there is no name to derive,
but the id still goes to plan. With no id, plan writes its date-slug id as before.

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
| critique | `gantry-critic`, **always, in every mode** | reading `task.md` and `plan.md` cold and returning findings | `.claude/agents/critic.md` |
| grill | — | it converses; the critique it chains is `plan-critique`'s dispatch, never its own | — |
| implement | — | the phase writes the code; the gate is a script | — |
| review | `gantry-reviewer`, when `/code-review` is unavailable — inside a **headless child session**, not the driver's | reading a diff it did not write | `.claude/agents/reviewer.md` |

**Every agent gantry ships is read-only.** `gantry-explorer` and `gantry-critic` have `Read, Grep,
Glob`; `gantry-reviewer` adds `Bash` to read git and run checks.
None can write, however it is prompted — a boundary prose cannot enforce. Writing therefore happens
in the phase skill, in the caller's own context, where it is visible rather than reported.

**Resolution is per role, repo first, independently** — and the *phase* does it, not the driver. A
repo that has tuned one agent to its codebase overrides that one and inherits the rest. A driver's
job is to say, at the end, which agents the phases reported actually dispatching.

**Why a driver still carries `Agent` in `allowed-tools`.** Not to dispatch phases. A skill's
frontmatter *restricts* what is permitted while it is active; it does not grant. So a driver must
permit every tool the phases it invokes need — `Agent` included, or `plan-critique` cannot dispatch
its critic.

If a dispatch fails with an unknown agent type, the repo's roster was added mid-session and needs a
restart. **Do not silently fall back to doing the work inline** — a phase whose delegation is
optional is one you cannot trust to have delegated.

**All handoff is via disk.** Never assume an agent can see your context or another agent's. Give it
paths and let it read them; take back a summary, not the payload.

## Headless phases

Review is the first phase that does not run in the driver's session at all. By stage 5 the
driver's context holds the plan, the critique and the whole implementation; in the one `auto` run
on disk, `/code-review` started at 187k tokens of context and ran inline, so the diff was reviewed
by the model that wrote it. So both drivers, and `gantry:ship --review`, launch it as a fresh
`claude -p "/gantry:review --headless …"` child through `lib/run_phase_headless.sh`, wait for the
completion notification (the launcher runs with `run_in_background`; there is no polling loop),
and read the results from disk: the launcher's labeled lines, `review.md`, and `task.md`'s status.

The phase skill still carries the procedure. What the launcher owns is the **boundary**, set by the
harness rather than by prose: the review child runs under `--permission-mode dontAsk` with an
allowlist of exactly `Edit(<artifact>)` and `Edit(//<root>/<artifact>)` for `review.md`,
`handover.md` and `task.md` (the relative form resolves against the child's current directory,
which a `cd` moves; the absolute form holds wherever the shell ended up), `Skill(gantry:handover)`
(a plugin skill is denied under `dontAsk` without it), and Bash rules for four read-only gantry
scripts (the gate, the exclusion writer, the stage detector, the diff fingerprint — each in both
quote forms, because a rule matches the literal command). It can write the chain's artifacts and
nothing else. The fix step is a **second child**, `gantry:review --fix`
under `acceptEdits` with the same Bash rules, which applies what `review.md` lists and re-runs the
gate. The driver never sees the child's transcript; a human who wants it uses
`claude --resume <session id>`, and the id is in the driver's report and the journal.

What the launcher's exit code means, and what a `DENIED:` line does not: `docs/ARCHITECTURE.md`
§ *Headless phases*.

### Preconditions for unattended — no blocking prompts

`gantry:auto-unattended` runs headless, so there is no human to answer a mid-run question, and one
would hang the run:

- **`gantry:worktree`** asks (AskUserQuestion) when the current branch isn't the base, to confirm
  the parent. Avoid it: start the run **from the base branch**, and pass `--branch` to fix the name
  up front.
- **`gantry:ship`** pauses to ask how to split when it sees several unrelated changes. Keep the task
  single and coherent so the diff is one change.
- **`gantry:plan`** asks only what it cannot draft without, in every mode; everything else it
  records in *Open questions* and leaves open. It does not take a reading of its own — see below.
- **`gantry:grill`** is human-only and therefore **not in this chain at all.** Unattended invokes
  `/gantry:plan-critique` directly. The critique is what survives; the conversation is what this
  mode gives up.

If a prompt is unavoidable for a given task, that task isn't a fit for unattended — run it
supervised.

### The one prompt unattended cannot route around

A genuine design fork is the exception to everything above, and it is deliberate. Unattended does
not avoid the question by answering it conservatively; it **stops**:

- `lib/detect_stage.sh` reports `FORKS:open|none|unknown|absent` from `task.md`'s *Open questions*.
  An unchecked box, or a bare bullet with no box, is open.
- `plan` **records** forks rather than asking them, in every mode. `plan-critique` can open one that
  planning never had, and records it the same way.
- **Supervised** settles them inside `grill`, as priced options in the rounds. Grill will not reach
  its terminal question while an entry is unchecked, so a supervised run cannot carry an open fork
  past it. Planning time is the cheap moment: the same fork found at review has an implementation on
  top of it.
- **Unattended** journals an `escalation` event, sets `status: blocked`, hands over, and stops.
- `gantry:implement` refuses on `FORKS:open` when `mode:` is `auto` or `unattended`, so the
  guarantee holds even if a driver's own check were skipped. Typed by hand it warns instead — a
  hand-driven run iterates between phases, and a note to yourself should not lock you out.

The reasoning is the same as the gate's. A conservative reading of a fork is still a decision
nobody made, and once it is written into a plan it is indistinguishable from one somebody did. A
blocked run costs a re-run; a wrong assumption costs the work built on it.

## Where `gantry:auto` stops

Two stops, and they are different kinds of thing:

1. **The grill conversation**, which is a phase rather than a checkpoint. `/gantry:grill` explains
   the problem, settles the open forks in priced options, and its **terminal question is the plan
   approval**. There is no separate "Proceed with this plan?" dialog: a yes at the end of a
   conversation is worth more than a yes in front of a wall of text, and the old dialog was the
   cheapest possible form of input on a plan the user had just been handed. Grill is also the last
   cheap moment to **catch a wrong branch name** — nothing has been edited yet, so the worktree
   costs one command to recreate; after `implement` there is a diff to move.
2. **One `AskUserQuestion` checkpoint, after review, before anything outward-facing.** The gate is
   green and the review is in hand. "Commit, push, and open the PR?" One gate in front of every
   side effect, since `gantry:ship` won't pause once invoked.

So `gantry:auto` contains exactly one `AskUserQuestion` checkpoint. Everything else it asks, it asks
through `grill`.

No checkpoint between implement and gate — the gate is the check there, and it is automatic. And no
checkpoint on either side of grill: its whole job is to make the plan worth approving, so the
approval belongs at the end of it rather than after it.

**A driver must not write `status: grilled` itself.** Grill leaves `critiqued` precisely when it did
not converge — a fork still open — and with the fork rounds gone there is no later round to catch
that. A driver that overwrote the status would be asserting an approval nobody gave; it stops and
surfaces the fork instead.

### Lead mode

Under `gantry:auto --lead <session>`, the checkpoint, grill's rounds, and the questions the phases
ask themselves are put to the lead with `SendMessage` instead of `AskUserQuestion`.
`references/lead.md` is the whole protocol, and every asking phase points at it: which questions it
replaces and of which kind, what the message carries, how a reply is classified by
`lib/lead_reply.sh` rather than read, what a lead may decide and what stays the owner's, and how the
run leaves lead mode.

The lead reaches the phases the way the task does. Before `task.md` exists the driver passes it as an
argument (`gantry:worktree`, `gantry:plan`). After that it is a `lead:` line in `task.md`'s
frontmatter, which the driver removes whenever the run ends.

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
