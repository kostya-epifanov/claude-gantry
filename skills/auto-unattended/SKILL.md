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

`$ARGUMENTS` is one string; read it yourself. Recognise `--no-pr`, `--branch <name>`, `--here`
(alias `--on-current`), `--base <branch>`; strip them; the remainder is the task. **If no task text
remains, stop and report** — there is nobody to ask.

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

Derive a branch name from the task (or take `--branch`), then **invoke `gantry:worktree`**.

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
use the id you are about to give it. Every command in this file is written flat — no substitution,
no heredoc, no pipe into a loop — because a worktree-isolated session refuses anything else; see
`references/journal.md` for what that refusal cost before it was fixed.

## Stage 2 — Plan

**Invoke `/gantry:plan`** with the task. It writes `task.md` and `plan.md`, and dispatches the
explorer itself when the surface warrants it.

Set `task.md`'s `mode:` to `unattended` — that is how `implement` and `review` learn to run the gate
`--strict` without being told. **Never clobber a task that is in flight**: under `--here`,
`TASK:present` means stop and report, not overwrite.

`TASK:inherited` is not that case and must not be treated as it. `task.md` is committed with every
pull request, so a branch cut from the base branch is born holding the last merged contract —
which is the normal state of a worktree this skill just created, not a task someone is working on.
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

## Stage 3 — Grill

**Invoke `/gantry:grill`.** It dispatches a fresh critic against the artifacts on disk — paths, not
contents — and triages what comes back.

This phase matters more here than anywhere else: it is the only scrutiny the plan will get before
implementation, because there is no checkpoint behind it. If grill sets `status: blocked`, **stop**
— journal it, hand over, and report. Do not proceed on a plan that did not survive.

**Check `FORKS:` again, on the same terms as stage 2.** A critique that surfaces a genuine design
fork records it rather than absorbing it, so grill can open one that planning never had — and the
stage 2 check ran before the critic did. `FORKS:open` here ends the run exactly as it does there:
journal the `escalation`, set `status: blocked`, hand over, stop.

Journal a `phase` event, naming the critic that ran:

```bash
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event stage --from plan --to grill --mode unattended
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event phase --phase grill --result ok --agent gantry-critic --summary <findings by severity, in a sentence> --artifact plan.md
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

**Invoke `/gantry:review`.**

It gets an independent read — `/code-review` if available, otherwise a reviewer sub-agent it
dispatches itself — fixes what is clearly in scope, re-runs the gate, and invokes
`gantry:handover` for what it defers. With no human to arbitrate, `review` defers rather than
expands — which is the right default, and means a `handover.md` is the normal outcome here rather
than an exceptional one.

Record which review tier actually ran. If it fell through to self-review, the report must say so:
an unattended run that also reviewed itself has had no independent scrutiny at all.

Journal a `phase` event, naming the tier and any sub-agent it dispatched:

```bash
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event stage --from implement --to review --mode unattended
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event phase --phase review --result ok --agent gantry-reviewer --summary <which tier ran, what it found, what was deferred> --artifact handover.md
```

Drop `--agent` when `/code-review` ran instead of a sub-agent; `agents` is then `[]`, which is the
documented way to record that a phase dispatched none.

## Stage 6 — Ship

Set `task.md` to `status: shipped` **first**, then **invoke `gantry:ship --draft --reviewed`**,
passing `--no-pr` and `--base` through if given. That order matters: ship commits the tree, so a
status written afterwards would miss the commit — the PR would carry a stale `status:` and the
worktree would be left dirty.

`--reviewed` is not optional here. Ship runs its own `/code-review --fix` stage for callers who
reach it directly; stage 5 already reviewed this change, and a second pass would let `--fix` apply
findings `/gantry:review` deliberately deferred to `handover.md`.

`task.md`, `plan.md`, and any `handover.md` are committed with the change. `journal.jsonl` and the
gate logs stay excluded.

The PR is a **draft**, always. Journal the final `stage` event once ship returns:

```bash
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event stage --from review --to ship --mode unattended
```

```bash
bash "$GANTRY/lib/journal_append.sh" --task <task-id> --event disclosure --stage ship --kind <slug> --detail <what was not proven, verbatim> --pr <pr url>
```

Journal a **`disclosure`** event for anything ship reported that this run did not prove — a
non-empty `human_only` block in `task.md`, or a change to the plugin's own files that the run could
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
- Which review tier ran, named plainly.
- **Every assumption `plan` or `grill` had to make** because there was nobody to ask. Genuine
  design forks are not on this list — those stop the run rather than becoming assumptions — but
  the judgement calls inside a plan still are, and the reader of a draft PR needs them.
- **What the run shipped without proving**, repeated from ship's report: whether `task.md` carried
  acceptance criteria no gate could check, and whether the diff changed the plugin's own skills,
  lib, hooks or agents — in which case, which plugin version actually executed. Draft status
  substitutes for neither: **draft means unwatched, not unverified.**
- What was deferred, and the `handover.md` path.
- The artifact paths, including `journal.jsonl` for the full trail.

If the run stopped early — blocked gate, blocked plan, **an open fork**, `NO-GATES`, broken
environment — lead with that and what would unblock it. For a fork, "what would unblock it" is the
decision itself: state the question and the options, so answering it is one message rather than a
re-investigation. A stopped run reported plainly is worth more than a finished one reported
vaguely.
