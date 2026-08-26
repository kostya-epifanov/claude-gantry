# Skills reference

Nine skills. Each section: what it does, its arguments, what it **refuses** to do, what it invokes,
and the scripts it owns. For the design argument see [METHOD.md](METHOD.md); for how they connect,
[ARCHITECTURE.md](ARCHITECTURE.md).

## Shared flags

`auto` and `factory` take the same flags, parsed from one argument string — there is no flag
parser, the skill reads them itself and what remains is the task.

| Flag | Effect |
|---|---|
| `--autonomous` | Drop both checkpoints and run unattended. A red gate triggers a capped fix loop instead of stopping. |
| `--no-pr` | End after the upload; don't open a PR. Passed through to `ship`. |
| `--branch <name>` | Use this exact branch name instead of deriving one from the task. |
| `--here` (alias `--on-current`) | Skip worktree creation; run on the branch you're already on. Mutually exclusive with `--branch`. |
| `--base <branch>` | Override the PR base branch. Passed through to `ship` and its detector. |

**Supervised vs autonomous is one axis, not two flags.** Supervised is the default. They differ
only in checkpoints and in what a red gate does — the gate itself is a hard blocker in both.

| | Supervised (default) | Autonomous |
|---|---|---|
| Checkpoints | two (after the plan; before anything outward-facing) | none |
| Red gate | report and stop | fix and retry, capped at 2 attempts |
| Gate invocation | `run_gates.sh` | `run_gates.sh --strict` |
| No checks found | continue, flag it (exit 0) | **refuse to ship** (exit 3) |

Autonomous runs headless, so no sub-skill may block on a prompt. Start the run **from the base
branch** (so `worktree` doesn't ask which parent to use) and keep the task single and coherent (so
`ship` doesn't ask how to split the diff). If a prompt is unavoidable, that task isn't a fit for
`--autonomous`.

---

## `/gantry:auto` — task to PR, one context

`/gantry:auto <task> [flags]`

Ten stages: parse args → worktree → plan → implement → **gate** → review → commit → upload → PR →
report. It doesn't do the work in a special way; it runs the same chain you'd run by hand, in
order, with one non-negotiable checkpoint.

**Review is independent by construction.** It uses the first available of: `/code-review`, then a
fresh review subagent given the diff and the task, then self-review — and it **always names which
one ran** in the report, because a self-review is a materially weaker check and hiding that would
make the report useless.

- **Refuses:** to proceed past a non-zero gate; to run `--here` on the default branch or a detached
  HEAD; to ship at all under `--autonomous` when no checks were found.
- **Invokes:** `gantry:worktree` (stage 1), `gantry:ship` (stages 6–8).
- **Scripts:** `scripts/run_gates.sh` — the shared hard gate, also used by `factory`.
- **Detail:** `references/orchestration.md`.

## `/gantry:factory` — the delegated twin

`/gantry:factory <task> [flags]`

The same pipeline, with exploring, planning and implementing dispatched to scoped sub-agents
against an on-disk contract (`task.md`, `plan.md`, `journal.jsonl`). Use it when the task would
otherwise flood one context with material the orchestrator will never need again.

Roster resolution is per role, repo first: `.claude/agents/<role>.md` if the repo defines it,
else the shipped `gantry-<role>`. A run is never blocked on a missing roster.

- **Refuses:** the same gate refusals as `auto`. Never delegates the gate — the gate is a script.
- **Invokes:** `gantry:worktree`, `gantry:ship`, and the roster.
- **Scripts:** shares `auto`'s `run_gates.sh` deliberately — one script, one contract.
- **Detail:** `references/task-contract.md`; flags and modes live in `auto`'s orchestration
  reference and are not duplicated.

## `/gantry:ship` — commit, upload, PR

`/gantry:ship [--no-pr] [--base <branch>]`

An idempotent stage machine. It runs `detect_state.sh` once, routes on the reported stage, and
falls through the remaining steps without re-detecting. Safe to run repeatedly from wherever the
branch already is.

Typing `/gantry:ship` **is** the go-ahead — it does not ask for stage-by-stage confirmation. It
matches the *target repo's* commit conventions, including whether that repo uses trailers, which
is exactly why `auto` and `factory` delegate the tail to it instead of imposing their own style.

- **Refuses:** to run on the repo's default branch; to rewrite history on a diverged branch; to
  bundle several unrelated changes without asking how to split them.
- **Degrades:** with `gh` missing or unauthenticated it still commits and uploads, then prints the
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

## `/gantry:status` — where am I

`/gantry:status [focus]`

Strictly read-only. Runs a snapshot script for the git facts, skims any plan files it surfaced,
then infers process state and reports Where / Sync / In flight / Plans / Next, weighted toward an
optional focus argument.

- **Scripts:** `scripts/snapshot.sh`.

## `/gantry:preserve` — session handoff

`/gantry:preserve [label]`

Writes a handoff document capturing what exists **only in the conversation**: decisions and why,
alternatives rejected and on what grounds, findings including dead ends, open threads, and the
exact next action. It gathers from the conversation, deliberately not from the repo.

Docs land at `~/.claude/sessions/<repo-slug>/<date>-<slug>.md` — outside the repo, so a worktree
prune can't destroy them and `git add -A` can't sweep them in. Same day plus same label means the
same file, and it reads an existing doc before overwriting.

The closing check is the point: *could a session with no memory pick up from this file alone?*

- **Deliberately not `status`:** no sync state, no uncommitted-file lists, no commit dumps.
- **Scripts:** `scripts/doc_path.sh`.

## `/gantry:skill` — author a new skill

`/gantry:skill <name>`

Ten steps to add a skill: validate the name → harvest intent from the conversation before asking →
settle frontmatter → write a body under 500 lines → **validate in a loop** with both
`claude plugin validate --strict` (manifest) and `validate_skill.py` (frontmatter, which the former
does not cover) → measure always-on vs on-invoke cost → prove it registered after `/reload-plugins`
→ document → optionally eval → commit.

It detects where it is running from: an installed plugin cache is read-only in practice, so it
scaffolds a standalone skill into `~/.claude/skills/` instead and says so.

- **Refuses:** names containing `claude` or `anthropic` (reserved), or a `gantry-` prefix (the
  plugin already supplies the namespace).
- **Scripts:** `scripts/validate_skill.py` (`uv run`, PEP 723).
- **Detail:** `references/authoring.md`.

---

## Context cost

Descriptions are always-on; bodies are paid per invocation. Measure it yourself with
`claude plugin details gantry@claude-gantry`. At v0.1:

| Component | Always-on | On-invoke |
|---|---|---|
| auto | ~150 | ~2.2k |
| factory | ~190 | ~3.5k |
| sync | ~170 | ~3.8k |
| ship | ~150 | ~1.5k |
| preserve | ~150 | ~1.5k |
| status | ~110 | ~470 |
| prune-worktrees | ~90 | ~1.3k |
| worktree | ~60 | ~2k |
| skill | ~60 | ~1.5k |
| the four agents | ~230 combined | ~390–480 each |
| **total always-on** | **~1,327** | |

Estimates from the CLI, rounded, and they will drift as the skills change. Re-measure rather than
trusting this table.
