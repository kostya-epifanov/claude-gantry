# Skills reference

Twelve skills. Each section: what it does, its arguments, what it **refuses** to do, what it
invokes, and the scripts it owns. For the design argument see [METHOD.md](METHOD.md); for how they
connect, [ARCHITECTURE.md](ARCHITECTURE.md).

They fall into three groups: the **phase skills** that make up the chain, the two **drivers** that
run that chain for you, and the **maintenance** skills around it.

## The three modes

One chain of phases, three ways to run it.

| | Semi-auto | `auto` | `auto-unattended` |
|---|---|---|---|
| Driver | you, typing each phase | the skill | the skill |
| Phases run | in your session | invoked by the driver | invoked by the driver |
| Stops | after every phase | two checkpoints | never |
| Red gate | you decide | report and stop | fix and retry, capped at 2 |
| Gate invocation | `run_gates.sh` | `run_gates.sh` | `run_gates.sh --strict` |
| No checks found | continue, flagged | continue, flagged | **refuse to ship** (exit 3) |
| PR | ready | ready | **draft** |

Semi-auto has no driver skill — it *is* the phase skills, typed in order. The gate is a hard
blocker in all three; unattended removes the human checkpoints, never the gate.

**There is no `--autonomous` flag.** It existed in v0.1 and was replaced by a separate skill: a flag
that silently removes every checkpoint is too easy to append to a command you meant to supervise.

Unattended runs headless, so no sub-skill may block on a prompt. Start the run **from the base
branch** (so `worktree` doesn't ask which parent to use) and keep the task single and coherent (so
`ship` doesn't ask how to split the diff). If a prompt is unavoidable, that task isn't a fit for it.

## Shared flags

Both drivers take the same flags, parsed from one argument string — there is no flag parser, the
skill reads them itself and what remains is the task.

| Flag | Effect |
|---|---|
| `--no-pr` | End after the push; don't open a PR. Passed through to `ship`. |
| `--branch <name>` | Use this exact branch name instead of deriving one from the task. |
| `--here` (alias `--on-current`) | Skip worktree creation; run on the branch you're already on. Mutually exclusive with `--branch`. |
| `--base <branch>` | Override the PR base branch. Passed through to `ship` and its detector. |

---

# The phase skills

Each is invocable on its own and each works out where things stand by running
`lib/detect_stage.sh` — reading `task.md`'s `status:`, which artifacts exist, and the tree's
state. **None of them reads the conversation**, which is what lets you drop out of the chain, work
by hand, and pick it back up.

**Two hard refusals, and only two — both `implement`'s:** it refuses to start without a `plan.md`,
and it refuses to move past a non-zero gate. Everything else warns and proceeds, naming what was
missing. Since you may iterate by hand between phases, a stale or absent artifact is a normal state
rather than an error.

`ship` does **not** re-check the gate — it commits, pushes, and opens the PR from wherever the
branch is. What stops a red tree reaching a PR is `implement` (and, where the repo has registered
it, the readiness hook), not `ship`.

## `/gantry:plan` — the contract and the plan

`/gantry:plan <task>`

Writes `task.md` (context and goal, acceptance criteria, how to verify, out of scope) and then
`plan.md`, asking whatever a genuine fork requires before any code is written. May dispatch the
explorer for the *Affected areas* section when the surface is unfamiliar; reads directly when it
isn't, and says which it did.

- **Refuses:** to clobber an existing `task.md` or `plan.md` — it offers to revise instead.
- **Warns:** when you are on the repo's default branch. Writing a plan there harms nothing.
- **Invokes:** the explorer, conditionally.
- **Templates:** the repo's `docs/templates/task.md` if it has one, else `templates/task.md`.

## `/gantry:grill` — attack the plan

`/gantry:grill`

Hunts unstated assumptions, unfalsifiable acceptance criteria, steps that will fail on contact with
the code, missing work, and scope drift. Revises `plan.md` and records what changed.

**It always dispatches a fresh critic sub-agent, in every mode — including when you type it
yourself.** A context that just wrote the plan already believes its assumptions and has already
dismissed the alternatives; self-critique from there is theatre. The critic is given the file paths
and no planning conversation, on purpose.

- **Refuses:** to invent a plan in order to critique it — no `plan.md` means nothing to grill.
- **Invokes:** `gantry-critic`; `gantry:handover` if the task itself turns out to be wrong.
- **Honest about its limits:** a critique that found nothing is reported as such rather than padded.

## `/gantry:implement` — carry it out, and prove it

`/gantry:implement`

Sets `status: implementing` **before touching a file** — that value is what arms the readiness hook,
and setting it afterwards would mean the gate was never enforced on the edits. Then executes
`plan.md` and runs the gate.

This phase owns the gate loop, because "implemented" and "passes the checks" are the same claim.

- **Refuses:** to start without a `plan.md`; to proceed past a non-zero gate.
- **Warns:** when the plan was never grilled.
- **Reports:** the gate's exit code verbatim, and whether the hook was **armed or inert** — a run
  with an inert hook was self-policed, and blurring the two is the one lie the chain can't absorb.
- **Scripts:** `lib/run_gates.sh`.

## `/gantry:review` — independent read, then act

`/gantry:review`

Three tiers, and it **always names which one ran**: `/code-review`, then a `gantry-reviewer`
sub-agent, then self-review — the last being materially weaker, which is exactly why hiding it
would make the report useless.

Then it triages. Findings inside the change's own footprint get fixed and the gate re-run; findings
outside the contract get **deferred**, not fixed. The dividing line is scope, not difficulty: a
one-line fix outside the contract is still deferred, because widening a change to absorb what
review turned up is how a focused diff becomes an unreviewable one.

Gets the diff with `git diff <base>` plus `git status --short`, because the tree is normally
uncommitted at this point and a three-dot range would come back empty.

- **Refuses:** to expand scope in order to fix a finding.
- **Invokes:** `gantry:handover` for everything deferred.
- **Scripts:** `lib/run_gates.sh`, after any fix.

## `/gantry:handover` — what this change left

`/gantry:handover [what]`

Writes `handover.md` at the worktree root: what was deferred, why it is out of scope, what was
already established including dead ends, and one concrete next action. Committed with the branch,
so it arrives with the pull request.

Not the same as `preserve`: this captures deferred **work** for whoever picks up the PR; `preserve`
captures conversation **reasoning** for the next session, outside the repo. Doing both is often
right.

- **Refuses:** to overwrite an existing `handover.md` — a second deferral appends.
- **Refuses:** to write an empty file. Nothing deferred, no artifact.

---

# The drivers

## `/gantry:auto` — task to PR, supervised

`/gantry:auto <task> [flags]`

Creates the worktree, then invokes each phase skill in turn, pausing twice: after the plan has been
grilled, and before anything outward-facing. Opens a **ready-for-review** PR.

**It contains no phase logic.** It is the same skills you would type, invoked in order — which is
what stops the three ways of running from becoming three subtly different pipelines. It dispatches
no sub-agents of its own; each phase delegates its own sub-job.

- **Refuses:** to proceed past a non-zero gate; to run `--here` on the default branch or a
  detached HEAD.
- **Invokes:** `gantry:worktree`, the four phase skills, `gantry:ship`.
- **Detail:** `references/orchestration.md`, shared with `auto-unattended`.

## `/gantry:auto-unattended` — the same chain, nobody watching

`/gantry:auto-unattended <task> [flags]`

No checkpoints, `--strict` gate, a `journal.jsonl` trail, and a **draft** PR — nobody reviewed this
live, so it must not page reviewers as though someone had.

Roster resolution is per role, repo first — `.claude/agents/<role>.md` if the repo defines it, else
the shipped `gantry-<role>` — and the *phase* does it, not the driver. A run is never blocked on a
missing roster.

Its report is written for someone who was not there, because nobody was: every assumption `plan` had
to make without being able to ask, which agents the phases actually dispatched, which review tier
ran, the gate's exit code on every run, and whether the hook was armed.

- **Refuses:** to push when no checks were found; to proceed on a plan that failed its critique;
  to fall back to inline work when a dispatch fails.
- **Never delegates the gate** — the gate is a script, and its exit code is deliberately not a
  model's judgment.
- **Detail:** `references/delegation.md` and `references/journal.md`; flags and modes live in
  `auto`'s orchestration reference and are not duplicated.

---

# Maintenance

## `/gantry:ship` — commit, push, PR

`/gantry:ship [--no-pr] [--draft] [--base <branch>]`

An idempotent stage machine. It runs `detect_state.sh` once, routes on the reported stage, and
falls through the remaining steps without re-detecting. Safe to run repeatedly from wherever the
branch already is.

Typing `/gantry:ship` **is** the go-ahead — it does not ask for stage-by-stage confirmation. It
matches the *target repo's* commit conventions, including whether that repo uses trailers, which is
exactly why the drivers delegate the tail to it instead of imposing their own style.

- **Refuses:** to run on the repo's default branch; to rewrite history on a diverged branch; to
  bundle several unrelated changes without asking how to split them.
- **Degrades:** with `gh` missing or unauthenticated it still commits and pushes, then prints the
  `gh pr create` command for you.
- **Scripts:** `scripts/detect_state.sh` (read-only; also used by `sync`).

## `/gantry:worktree` — open a lane

`/gantry:worktree <branch>`

Creates `.claude/worktrees/<branch>` on that branch in the **main** repo (resolved via
`--git-common-dir`, so worktrees never nest) and enters it. Base detection prefers `develop` when
it exists, then `origin/HEAD`, then `master`/`main`, and asks which parent to use when the current
branch differs.

Much of this skill is hard-won failure handling: the fetch is verified rather than assumed;
`ls-remote` exits 0 whether or not it matched, so a remote branch counts as existing only when the
**output is non-empty**; and all four collision cases (local + worktree / local only / remote only,
adopted with tracking / neither) are handled distinctly.

- **Refuses:** to nest a worktree inside another worktree.
- **Scripts:** none — the procedure is the skill.

## `/gantry:sync` — close the lanes

`/gantry:sync [base-branch]`

Eight stages: locate the main repo → **refuse on a dirty tree** → `fetch --prune` → resolve the
base → checkout → `merge --ff-only` → report what became prunable → hand off to `prune-worktrees`.

Base resolution: an explicit argument (pre-validated; a typo is a hard stop, not a silent switch),
then the optional external profile resolver, then `ship`'s detection.

- **Refuses:** to run on a dirty main tree; to stash, merge non-fast-forward, rebase, reset, or
  rewrite history on your behalf; to delete branches; to change the session's directory.
- **Honest about its limits:** merge classification only works for `develop`/`master`/`main`; any
  other base gets an explicit "merge classification unavailable" note rather than a confident wrong
  answer.
- **Invokes:** `gantry:prune-worktrees`.
- **Scripts:** none of its own — reuses `ship`'s and `prune-worktrees`'.

## `/gantry:prune-worktrees` — remove what's done

`/gantry:prune-worktrees`

Buckets every worktree (stale at 7+ days idle, or merged into develop/master/main), summarises each
candidate's last five commits, then asks: review individually, prune all, or abort. Review is
batched in groups of four with **nothing checked by default**, and every selected path gets a
`git status --porcelain` safety re-check immediately before removal.

- **Refuses:** to delete branches — scope is worktree checkouts only. It prints the manual
  `git branch -d` line and leaves the decision to you.
- **Scripts:** `scripts/detect_candidates.sh`.

## `/gantry:preserve` — session handoff

`/gantry:preserve [label]`

Writes a handoff document capturing what exists **only in the conversation**: decisions and why,
alternatives rejected and on what grounds, findings including dead ends, open threads, and the
exact next action. It gathers from the conversation, deliberately not from the repo.

Docs land at `~/.claude/sessions/<repo-slug>/<date>-<slug>.md` — outside the repo, so a worktree
prune can't destroy them and `git add -A` can't sweep them in. Same day plus same label means the
same file, and it reads an existing doc before overwriting.

The closing check is the point: *could a session with no memory pick up from this file alone?*

- **Deliberately not a git report:** no sync state, no uncommitted-file lists, no commit dumps.
- **Scripts:** `scripts/doc_path.sh`.

---

## Context cost

Descriptions are always-on; bodies are paid per invocation. Measure it yourself with
`claude plugin details gantry@claude-gantry` — and trust that over this table.

| Component | Always-on |
|---|---|
| auto | ~130 |
| auto-unattended | ~130 |
| plan | ~70 |
| grill | ~90 |
| implement | ~80 |
| review | ~80 |
| handover | ~90 |
| ship | ~160 |
| sync | ~170 |
| worktree | ~60 |
| preserve | ~150 |
| prune-worktrees | ~90 |
| the three agents | ~190 combined |
| **total always-on** | **~1,464** |

**These are measured, not derived** — `claude --plugin-dir . plugin details gantry`, against the
v0.3 tree. v0.2 published a figure scaled from v0.1's reading, which is exactly the kind of claim
this project argues does not belong in prose; the number is now read from the tool and, more to the
point, **enforced**: `scripts/context_budget.sh` runs in `scripts/verify.sh` and fails the build
when the descriptions outgrow a declared ceiling.

Against v0.1's measured ~1,157, v0.3 costs about a quarter more — the price of five phase skills,
partly offset by deleting `gantry-verifier`, an agent nothing dispatched, which was ~70 of every
session's budget.

The phase skills carry deliberately terse descriptions, because the drivers and the standalone
skills are what you actually invoke by name; a phase is usually reached by typing the chain or by a
driver invoking it. Re-measure rather than trusting this table.
