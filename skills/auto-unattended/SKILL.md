---
name: auto-unattended
description: Runs a task from description to draft pull request with no human in the loop — creates a worktree, drives the gantry chain (plan, critique, implement, review, qa, ship) by invoking each phase skill in turn, keeps a journal.jsonl trail, and treats the repo's checks as the only blocker. Refuses to push if no checks were found. Built for headless use on a build box or in CI. Use when the user types "/gantry:auto-unattended" with a task, or asks to run something unattended, autonomously, or without supervision.
argument-hint: "[task] [--task <id>] [--no-pr] [--branch <name>] [--here] [--base <branch>] [--review-model <alias>] [--review-effort <level>]"
allowed-tools: Bash, Read, Write, Edit, Skill, Agent
---

# gantry:auto-unattended

The gantry chain with nobody watching: worktree → **plan → plan-critique → implement → review → qa** →
draft PR. No checkpoints, no questions, one blocker — the gate.

Built for `claude -p "/gantry:auto-unattended <task>" --dangerously-skip-permissions` on a build box
or in CI. Use `gantry:auto` when you are at the keyboard.

**This skill contains no phase logic** — every phase lives in its own skill, and this one invokes
them. It differs from `gantry:auto` in exactly four things: it never pauses, the gate runs
`--strict`, it keeps a journal, and it opens a **draft** PR.

**You do not dispatch sub-agents; the phases do.** `plan` dispatches the explorer when the surface
warrants it, `plan-critique` always dispatches a fresh critic, `review` dispatches an independent
reviewer — each scoped to its own sub-job and read-only by tool list. `Agent` is in this skill's
`allowed-tools` for that reason alone: frontmatter restricts what is permitted, it does not grant,
so a phase cannot dispatch what the driver has not allowed.

## What "unattended" removes, and what it does not

It removes the **human** checkpoints. It does not remove the gate, and it does not lower the bar
for shipping:

- A red gate is fixed at most **twice**, then the run stops `blocked`. It is never pushed past.
- An **open fork** stops the run. With nobody to ask, a genuine design decision is escalated, not
  guessed at — see stage 2. This is the one place unattended does *less* than supervised on
  purpose.
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

`$ARGUMENTS` is one string; read it yourself. Recognise `--no-pr`, `--branch <name>`,
`--task <id>`, `--here` (alias `--on-current`), `--base <branch>`, `--review-model <alias>` and
`--review-effort <level>`; strip them; the remainder is the task. `--review-model` and
`--review-effort` reach stage 5's launcher and nothing else; with neither, the review child
inherits the user's default model and effort. The tracker id and the `--branch` value are not read
by eye: write the whole string to a file and run `lib/task_id.sh` on it, as
`$GANTRY/skills/auto/references/orchestration.md` § *Deriving the branch name* describes — its
`TEXT:` line is the task with those two removed. **If no task text remains, stop and report** —
there is nobody to ask. Exit `2` from the parser (a `--task` or `--branch` with a missing or bad
value) is the same stop: report it, do not guess an id.

**`--lead` is not accepted here — stop and report.** It belongs to `gantry:auto`, where there are
questions to route to a lead; this skill asks none. Left unrecognised, `--lead <session>` would
silently become part of the task text.

Then look at what roster this repo will resolve to. The phases do the resolving, but a headless run
should say up front which agents it expects to see:

```bash
git ls-files --cached --others --full-name -- ':/.claude/agents/*.md' 2>/dev/null
```

The `:/` prefix anchors the pathspec to the repository root, so this is correct from anywhere in
the tree without resolving the root into a variable first.

That shape is deliberate. A worktree-isolated session refuses a command it cannot verify stays
inside the worktree, and a `ROOT=` assignment taken from a `git rev-parse --show-toplevel`
substitution, followed by a brace expansion, is exactly such a command — the same refusal that made
the journal idiom unusable. Every command in this file is written flat for that reason: no
substitution, no heredoc, no pipe into a loop.

Resolution is **per role, repo first**: a phase dispatches `$ROOT/.claude/agents/<role>.md` if it
exists, otherwise `gantry-<role>`. A repo may override one role and inherit the rest. **State what
each role will resolve to before stage 1**, and confirm it in the roll-call at the end against what
the phases actually reported dispatching.

A dispatch that fails with an unknown agent type means the repo's roster was added mid-session and
needs a restart. Stop and report it — do not fall back to doing the work inline.

## Stage 1 — Worktree and branch

Name the branch by `orchestration.md` § *Deriving the branch name* — `--branch` verbatim, else
`<type>/<ID>-<slug>` when `lib/task_id.sh` found a tracker id, else `<type>/<slug>` exactly as
before — then **invoke `gantry:worktree`**.

Start the run **from the base branch** so worktree doesn't stop to confirm the parent — a prompt
here hangs a headless run. Under `--here`, skip this and run on the current branch, stopping first
on a detached HEAD or the repo's mainline.

Then exclude the journal and gate artifacts, and append the first `stage` event:

```bash
bash "$GANTRY/lib/ensure_excluded.sh" journal.jsonl .claude/artifacts/
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event stage --to contract --mode unattended
```

`ensure_excluded.sh` writes to the exclude file git actually reads, which for a linked worktree is
the **main repo's** — git maps `info/` into the common git dir, so a per-worktree `info/exclude` is
a path git never reads. That file is therefore shared by every lane, and the obvious
`grep -q … || echo … >>` races: parallel lanes interleave the read and the write, and
double-appended entries were observed. The script locks, matches whole lines, and repairs
duplicates an earlier writer left, so it is safe to run from any number of lanes at once.

`--task` is the `id` from `task.md`. On this first line the task contract does not exist yet, so
use the id you are about to give it: the parser's `ID:` when it is not `-`, otherwise the
date-slug id `gantry:plan` will write. Every command in this file is written flat — no substitution,
no heredoc, no pipe into a loop — because a worktree-isolated session refuses anything else; see
`references/journal.md` for what that refusal cost before it was fixed.

## Stage 2 — Plan

**Invoke `/gantry:plan`** with the task — and with `--task <id>` when the parser found a tracker
id, so `task.md`'s `id:` is the same id as the branch and the journal. It writes `task.md` and
`plan.md`, and dispatches the explorer itself when the surface warrants it.

Set `task.md`'s `mode:` to `unattended` — that is how `implement` and `review` learn to run the gate
`--strict` without being told. **Never clobber a task that is in flight**: under `--here`,
`TASK:present` means stop and report, not overwrite.

`TASK:inherited` is not that case and must not be treated as it. In a repo that ran 0.4.x or
earlier `task.md` was committed with every pull request, so a branch cut from the base branch is
born holding the last merged contract — not a task someone is working on.
The detector distinguishes the two rather than leaving it to judgement, and `gantry:plan` routes
`inherited` to a clean start. Read the value and let it decide; a blanket "never overwrite" here
would stop every run on its own worktree.

Journal a `phase` event, naming any sub-agent the phase dispatched, then read `plan.md` back from
disk. Repeat `--agent` once per sub-agent, and drop it entirely when the phase dispatched none:

```bash
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event stage --from contract --to plan --mode unattended
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event phase --phase plan --result ok --agent gantry-explorer --summary <one or two sentences> --artifact task.md --artifact plan.md
```

### An open fork ends the run

Run `bash "$GANTRY/lib/detect_stage.sh"` and read `FORKS:`. On **`FORKS:open`** this run is over:

1. Journal an `escalation` event naming every open entry — one `--detail` per fork, each carrying
   the question verbatim rather than a count:

   ```bash
   bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event escalation --stage plan --reason open-fork --detail <the fork, verbatim> --status blocked
   ```

2. Set `task.md` to `status: blocked`.
3. Invoke `gantry:handover` so the fork reaches whoever picks this up.
4. **Stop.** Report the forks as the result.

There is no fourth option and nothing further to try. With nobody to ask, the only ways past a fork
are to guess or to stop, and guessing is what this exists to prevent: an assumption written into a
plan is indistinguishable from a decision, and by the time it surfaces there is an implementation
built on it. A blocked run costs a re-run once someone answers; a wrong assumption costs the work.

Do not dispatch `/gantry:implement`. It refuses on an open fork under `mode: unattended` anyway,
but reaching that refusal means dying mid-chain with no escalation event and no `blocked` status —
a stop nobody can act on.

On `FORKS:unknown` the file has no such section: say so and continue.

## Stage 3 — Critique

**Invoke `/gantry:plan-critique`.** It dispatches a fresh critic against the artifacts on disk —
paths, not contents — and triages what comes back. It asks nothing on any path, which is why this
mode can run it at all.

**This mode loses the conversation, not the critique.** `/gantry:grill` is human-only and has no
place here; `/gantry:plan-critique` is headless and keeps its place in every mode. Dropping both
would leave `plan → implement` with nothing in between, and make the first independent read of
anything happen *after* the code was written. That is an unforced loss, and it is why the phase was
split along mechanism versus interface rather than simply removed from this chain.

This phase matters more here than anywhere else: it is the only scrutiny the plan will get before
implementation, because there is no checkpoint behind it. If it sets `status: blocked`, **stop** —
journal it, hand over, and report. Do not proceed on a plan that did not survive.

**Check `FORKS:` again, on the same terms as stage 2.** A critique that surfaces a genuine design
fork records it rather than absorbing it, so it can open one that planning never had — and the
stage 2 check ran before the critic did. `FORKS:open` here ends the run exactly as it does there:
journal the `escalation`, set `status: blocked`, hand over, stop. Supervised runs settle such a fork
in `grill`; this mode has no one to ask, so it stops instead of guessing.

The phase leaves `status: critiqued`, and that is the status this mode carries into `implement` —
`grilled` is only ever written by `grill`, which does not run here. `/gantry:implement` accepts
`critiqued` without a warning for exactly this reason.

Journal a `phase` event, naming the critic that ran:

```bash
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event stage --from plan --to critique --mode unattended
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event phase --phase critique --result ok --agent gantry-critic --summary <findings by severity, in a sentence> --artifact plan.md
```

## Stage 4 — Implement

**Invoke `/gantry:implement`.** It works from the artifacts on disk, never a restatement of them.

`implement` owns the gate: it sets `status: implementing`, carries out the plan, runs
`run_gates.sh --strict`, and iterates on red at most twice. **Journal a `gate` event with the
literal exit code every time it runs**, with `attempt` incrementing:

```bash
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event stage --from grill --to implement --mode unattended
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event gate --result fail --exit <literal exit code> --attempt 1 --check <name> --coverage-verdict <verdict> --coverage-changed <n> --coverage-covered <n> --coverage-root <root> --artifact .claude/artifacts/gate-1.log
```

`--exit` takes the number the gate actually returned. Write it in literally — each of these runs
in a fresh shell, so a `"$RC"` would expand to empty and be refused. `--result` is `pass` for 0,
`fail` for 1 or 2, `no-gates` for 3.

Carry the phase's **coverage** report into that event's `coverage` field through the
`--coverage-*` flags — the verdict, the counts, and one `--coverage-root` per root, verbatim from
what `implement` reported. Omit all four on a run that produced no verdict; do not invent one. A green gate that read none of
the changed paths is **green-but-uncovered**: it still passes, it is still exit `0`, and nothing
is refused, but the journal must not record it identically to a gate that proved something. The
overlap is a heuristic; `references/journal.md` has the field's shape and the caveat that travels
with it.

- **Green** → continue.
- **Red after 2 attempts** → `status: blocked`. Stop. Do not push.
- **Exit 2** (the gate could not run) → stop and report a broken environment. It must not consume a
  fix attempt.
- **Exit 3** (`NO-GATES` under `--strict`) → stop and refuse to push. Suggest `.claude/gates.sh`.

Do not commit `journal.jsonl` at any point.

## Stage 5 — Review

**Do not invoke `/gantry:review` in this session.** Launch it as a fresh headless child through
`lib/run_phase_headless.sh` — the same launcher `gantry:auto` uses — and read its results from
disk. Your context holds the plan, the critique and the whole implementation; a reviewer that
inherits it is the author reviewing itself, and an unattended run has no other scrutiny. The phase
skill still carries the procedure; only where it runs changes
(`$GANTRY/skills/auto/references/orchestration.md` § *Headless phases*).

```bash
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event stage --from implement --to review --mode unattended
bash "$GANTRY/lib/run_phase_headless.sh" --phase review --root <worktree> --tier high
```

Run the launcher with the Bash tool's `run_in_background` and wait for the completion
notification; do not poll.

**Pass `--model` every time.** A child with no `--model` does not inherit this session's model —
it takes the user default from `settings.json`, which is a different thing. Pass `--review-model`'s
alias when it was given, otherwise the model this session is running on; an unattended run that
silently reviewed on whatever a stray `/model` command last saved is not a reproducible run. Pass
`--effort <level>` only when `--review-effort` was given, and `--plugin-dir "$GANTRY"` when
`$GANTRY` is not under `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/plugins/` (a checkout, not an install).

On a resume, check for `.claude/artifacts/headless/review.done` before launching again; if it is
absent, run the same command — the child outlives the launcher, so the launcher attaches to it by
its `.pid` rather than paying for a second review, and says so in a `NOTE:` line.

The child runs `/gantry:review --headless --tier high`: it gets an independent read, verifies and
triages, writes `review.md` with what is in scope to fix, invokes `gantry:handover` for what it
defers — with nobody to arbitrate it defers rather than expands, so a `handover.md` is the normal
outcome — and sets `status: reviewed`. It cannot edit code: the launcher gives it `dontAsk` and an
allowlist of exactly the chain's artifacts and gantry's read-only scripts.

**Read the launcher's lines, then route:**

- Exit `1` or `3` (the child did not complete, or left no `review.md`, or `claude` itself failed)
  → journal the phase as failed with its `REASON:`, set `status: blocked`, journal an
  `escalation`, invoke `gantry:handover`, and **stop**. Exit `2` → a broken environment; stop and
  report it as such, without a `blocked` status.
- Exit `0` → run `bash "$GANTRY/lib/detect_stage.sh"`. `STATUS:blocked` → the review found the
  change unsafe; journal, hand over, stop. Otherwise journal the phase with the child's session id:

```bash
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event phase --phase review --result ok --session <review child session id> --summary <which source ran, what it found, what was deferred> --artifact review.md --artifact handover.md
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event phase --phase review --result failed --session <review child session id> --summary <the launcher REASON line>
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event escalation --stage review --reason headless-child-failed --detail <the launcher REASON line, verbatim> --status blocked
```

The first line is the success shape, the other two the failure shape; write the one that
happened. **Omit `--session` when the launcher printed `SESSION:-`** — `claude` itself failed
before producing a result (launcher exit `3`), there is no session to name, and `-` is neither an
id `claude --resume` accepts nor the absent value `journal_append.sh` documents for a phase with
no child. Repeat `--agent gantry-reviewer` on the phase line only when `review.md`'s `source:` line
says that is what ran; with `code-review` or `self-review`, `agents` is `[]`. If it fell through to
self-review, the report must say so: an unattended run that also reviewed itself has had no
independent scrutiny at all.

- `REVIEW:pending` → launch the fix child the same way, with the same `--model`, `--effort` and
  `--plugin-dir`, and wait for it. It runs `/gantry:review --fix --headless` under `acceptEdits`,
  applies what `review.md` lists, re-runs the gate `--strict`, and appends `applied: … gate=<exit>`
  to the file. Read `GATE_EXIT:` from the launcher and journal it as a `gate` event with the
  literal code, exactly as stage 4 does; non-zero after the child's own two attempts → `status:
  blocked`, journal the `escalation`, stop. A launcher exit of `1` or `3` is the same stop as above.
- `REVIEW:clean` → nothing in scope to fix; say so, launch nothing.

```bash
bash "$GANTRY/lib/run_phase_headless.sh" --phase review-fix --root <worktree>
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event phase --phase review-fix --result ok --session <fix child session id> --summary <what was applied> --artifact review.md
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event gate --result pass --exit <literal exit code> --attempt 1 --artifact review.md
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event gate --result fail --exit <literal exit code> --attempt 1 --artifact review.md
```

The `gate` lines are the pass and the fail shape; write the one `GATE_EXIT:` says happened, with
`--result` as stage 4 defines it (`pass` for `0`, `fail` for `1` or `2`, `no-gates` for `3`) and
the literal code. A red fix-gate journaled as `pass` is a journal that lies about the one thing an
unattended run exists to prove.

## Stage 5b — QA

**Invoke `/gantry:qa`** — **without `--fix`.** It runs the task's e2e scenarios against the built
app if, and only if, the repo opted in with `.claude/agents/qa.md` and `.claude/qa-env.sh`, and
writes `qa.md`, which ship quotes into the draft PR's body. No `--fix` here: a UI-driven fix nobody
watched is the wrong kind of autonomy, and `review` already applied the fixes a reviewer judged in
scope. A failing scenario is **deferred** through `gantry:handover` and reaches the reviewer under
*Deliberately not done*, with its evidence paths.

It runs in this session, not in a headless child: the screenshots and UI trees are the repo's `qa`
sub-agent's context, and what comes back is a summary.

```bash
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event stage --from review --to qa --mode unattended
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event phase --phase qa --result ok --agent qa --summary <the outcome; on exercised, the verdicts in one sentence> --artifact qa.md
```

Repeat `--agent qa` only when the phase dispatched the repo's agent — the outcome was `exercised`.
On `no-agent`, `unrunnable` and `no-scenarios` nothing was dispatched and `agents` is `[]`.

Then read `bash "$GANTRY/lib/detect_stage.sh"` and route on `QA:`:

- `no-agent` → the normal case; journaled above, continue. Never a warning.
- `unrunnable` → continue; the `reason:` line goes in the summary. Ship puts the declared scenarios
  under *Not proven by this run*, and stage 6 journals that as a `disclosure`.
- `no-scenarios` → continue.
- `exercised` → continue, **unless** `STATUS:blocked`. The phase blocks on exactly one thing — a
  verified failure that falsifies a stated acceptance criterion — and with no `--fix` nothing could
  have repaired it, so the change provably does not do what its contract says. Then: journal the
  `escalation`, invoke `gantry:handover` if the phase has not, and **stop**.

```bash
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event escalation --stage qa --reason qa-criterion-false --detail <the scenario and the criterion it falsified, verbatim from qa.md> --status blocked
```

If `qa.md` lists **flow files**, the phase kept them in the tree and wrote a `handover.md` item
naming each one and the wiring it still needs; nobody was present to ask. Say so in the report —
a flow in a draft PR that nothing runs yet is the loop half-closed, and the reviewer closes it.

## Stage 6 — Ship

Set `task.md` to `status: shipped` **first**, then **invoke `gantry:ship --draft`**, passing
`--no-pr` and `--base` through if given. That order matters: ship commits the tree, so a status
written afterwards would miss the commit — the PR would carry a stale `status:` and the worktree
would be left dirty.

**Pass no review flag.** Ship reviews only when asked, and stage 5 already reviewed this change.
Passing `--review` or `--review-fix` here would review the same diff a second time — and under
`--review-fix`, reopen and apply findings `/gantry:review` deliberately deferred to
`handover.md`.

`task.md`, `plan.md`, `review.md`, `qa.md` and any `handover.md` are **not** committed — they are
excluded alongside `journal.jsonl` and the gate logs. Ship quotes the contract, the QA verdict and
the handover into the PR body, which for an unattended run is the reviewer's only interface to any
of them.

The PR is a **draft**, always. Journal the final `stage` event once ship returns:

```bash
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event stage --from qa --to ship --mode unattended
```

```bash
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event disclosure --stage ship --kind <slug> --detail <what was not proven, verbatim> --pr <pr url>
```

Journal a **`disclosure`** event for anything ship reported that this run did not prove — a
non-empty `human_only` block in `task.md`, e2e scenarios the task declared that QA did not run
(`unexercised-e2e`), or a change to the plugin's own files that the run could
not exercise. Repeat `--detail` once per item, and omit `--pr` under `--no-pr`, where the field is
recorded as `null`. Take it **from ship's report**, not from your own reading of the tree: the journal is
append-only and the project treats it as evidence, so an invented line is worse than a missing one.
If ship's report is silent on both, say *that* in the report rather than deriving them here.

## Stage 7 — Report

Written for someone who was not here, because nobody was:

- The task, the branch, the worktree path, the PR URL — and that it is a draft.
- Which roster each role resolved to, and a delegation roll-call: which agents the phases
  actually dispatched — the explorer if `plan` used one, the critic, the reviewer.
- The gate's exit code on every run, and the number of fix attempts used.
- Whether the readiness hook's firing conditions were **met or unmet**, and that this is not the
  same as the hook having fired: the detector cannot see registration. An unattended run whose
  conditions were unmet — or whose hook was never registered — was self-policed by a script it
  could have skipped; say so, and say which of the two you actually know.
- **The QA outcome**: `no-agent` (the normal case, stated as such), `unrunnable` with the
  environment's exit code and reason, `no-scenarios`, or `exercised` with one verdict per scenario
  and the agent's `tools:` line. Any flow files the run left in the tree, and that nothing runs
  them yet. A failing scenario that did not block was deferred; say so and where.
- Which review tier ran, named plainly — and **the review children**: the review child's session
  id and the fix child's (if one ran), the model and effort they ran with (effort `inherit` when
  none was passed), the gate exit the fix child recorded, and every permission denial verbatim
  from the launcher's `DENIED:` lines. A denial never fails the launcher on its own; it is reported
  so the reader can weigh what the review could not do.
- **Every assumption `plan` or `plan-critique` had to make** because there was nobody to ask. Genuine
  design forks are not on this list — those stop the run rather than becoming assumptions — but
  the judgement calls inside a plan still are, and the reader of a draft PR needs them.
- **What the run shipped without proving**, repeated from ship's report: whether `task.md` carried
  acceptance criteria no gate could check, and whether the diff changed the plugin's own skills,
  lib, hooks or agents — in which case, which plugin version actually executed. Draft status
  substitutes for neither: **draft means unwatched, not unverified.**
- What was deferred, and the `handover.md` path.
- The artifact paths, including `journal.jsonl` for the full trail.

If the run stopped early — blocked gate, blocked plan, **an open fork**, `NO-GATES`, broken
environment, a review child that failed — lead with that and what would unblock it. For a fork, "what would unblock it" is the
decision itself: state the question and the options, so answering it is one message rather than a
re-investigation. A stopped run reported plainly is worth more than a finished one reported
vaguely.
