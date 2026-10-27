---
name: integrate
description: Merges the ready open PRs one at a time into a fresh integration branch, resolving conflicts by what each PR is for, running the repo's checks after every merge, and opening one integration PR. Use when the user types "/gantry:integrate", or asks to integrate or combine the open PRs.
argument-hint: [<pr#> ...] [--base <branch>]
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Skill, Agent, AskUserQuestion
---

# gantry:integrate

Turn N open pull requests into **one** pull request whose combined tree passes the checks.

It reads the open PRs, states why it is leaving each unready one out, plans a merge order from a
conflict matrix computed **before anything is touched**, then merges the rest one at a time into a
fresh `integration/<date>` branch cut from the base. Every merge is a real merge commit, every
conflict is resolved from what the two PRs are *for*, and the gate runs after each one — so a
failure belongs to the PR that caused it rather than to the pile.

**Why it exists.** `gantry:auto-unattended` leaves a stack of drafts, each cut from the base and
each checked only on its own. They conflict with each other on the boring shared surfaces — docs
tables, counts, a version, a shared script — and a PR that passed alone can break once it meets the
others. **A green check on a PR says nothing about the combined tree.** This skill is what says
something about it.

**Supervised only.** Two checkpoints: the queue, before any work starts, and the pull request,
before anything outward-facing. There is no `--unattended` flag, on purpose — see
`docs/SKILLS.md`.

## What it will not do

- **Never touches a source PR's branch.** No push, no rebase, no close, no edit. The only write to a
  source PR is one comment, after you confirm it.
- **Never squashes or rebases.** Merge commits keep each PR's commits reachable, which is what lets
  GitHub mark the source PRs merged when the integration PR lands — see `references/pr-body.md`.
- **Never takes `--ours` or `--theirs` wholesale, and never drops a hunk.** A resolution is made
  from both PRs' stated intent, and recorded in the merge commit.
- **Never merges the integration PR.** That is yours.
- **Never continues past a red gate** by moving on to the next PR and hoping. It resets that merge
  out and says so.

## Before you start

Read `references/merge-loop.md` — the conflict rules, the fix-attempt cap, the reset guard, and
what a resumed or interrupted run has to do first. Read `references/pr-body.md` before composing
anything outward-facing.

`$GANTRY` is this skill's plugin root — resolve it from this file's own location rather than
hardcoding a path.

**Every command below is flat**: one invocation, no substitutions, no pipes, no chaining. Run them
one at a time and read the output. `tests/cases/integrate_flat_commands.sh` keeps that true.

## Stage 0 — Arguments

`$ARGUMENTS` is one string. Recognise PR numbers and `--base <branch>`. Numbers are an **explicit
list** and override discovery. Anything else, say what you did not understand and stop.

State the mode back in one line: which PRs (or "discover"), and the base if one was given.

## Stage 1 — Where this run stands

```bash
bash "$GANTRY/skills/ship/scripts/detect_state.sh"
```

```bash
bash "$GANTRY/skills/ship/scripts/detect_state.sh" --base <branch>
```

Read `BASE` (the base branch every candidate must target), `GH`, and `BRANCH`.

- `GH:missing` or `GH:unauth` → stop. Discovery, the contracts and the PR all need it.
- `DETACHED` → stop.
- **`BRANCH` starts with `integration/`** → this is a **re-run** in an existing lane. The base is
  not re-detected from scratch: take it from the lane's own integration PR when one exists
  (`gh pr view --json baseRefName`), else from `task.md`'s `base:` field at the worktree root. A
  `--base` that disagrees with either is a stop, not an override — the lane was cut from one base
  and can only target that one.

## Stage 2 — Candidates, and why each other PR is out

```bash
git fetch origin <BASE>
```

```bash
bash "$GANTRY/skills/integrate/scripts/list_candidates.sh" --base <BASE>
```

```bash
bash "$GANTRY/skills/integrate/scripts/list_candidates.sh" --base <BASE> 21 23 24
```

One block per PR, then `CANDIDATES:` and `SKIPPED:`. **The script decides this, not you** — do not
second-guess a verdict, and do not add one of your own.

What the classes mean when you show them:

- `DRAFT:yes` is **not** a reason to skip. Unattended runs open drafts, and those are the PRs this
  gathers.
- `CI:failing` is a skip. `CI:pending` and `CI:none` are candidates, and both are shown at the
  checkpoint: `pending` may still go red, and `none` means the PR's own checks never ran at all.
- `MERGEABLE` is reported and never acted on. Whether a PR can go in is decided in stage 3, against
  the base you just fetched.

Then read each candidate's contract — a gantry PR body carries `## What this change is for`,
`## Deliberately not done` and `## Not proven by this run`, and those are what you resolve conflicts
from later:

```bash
gh pr view <n> --json body
```

A `CONTRACT:none` PR still works. You have its title, its diff and its comments, and you say in the
report that you had no stated intent for it.

**An `INTEGRATION_PR:` line, or an existing `integration/*` worktree**, means a lane is already
open. Ask (AskUserQuestion) whether to resume it — which means re-running this command from *that*
worktree — or to start a new one.

## Stage 3 — The queue, planned before anything is touched

**Name the lane first**, because every ref this run writes is named after it:

```bash
date -u +%F
```

The lane is `integration/<that date>`. If a branch of that name already exists locally or on origin,
use the first free `-2`, `-3` suffix — appending to yesterday's lane by accident is how one
integration PR silently becomes two:

```bash
git show-ref --verify --quiet refs/heads/integration/<date>
```

```bash
git ls-remote --heads origin refs/heads/integration/<date>
```

`ls-remote` exits 0 whether or not it matched — a remote branch exists only when its **output is
non-empty**. On a re-run the lane is the branch you are already on.

Then fetch every candidate's head into a **lane-scoped** ref, in one command, so the objects are
present and stay reachable:

```bash
git fetch origin +refs/pull/21/head:refs/integrate/integration/<date>/pr/21 +refs/pull/23/head:refs/integrate/integration/<date>/pr/23
```

`refs/` lives in the **common** git directory, shared by every worktree of this repository, so an
unscoped `refs/integrate/pr/21` would be one ref two lanes fight over — one lane force-moving the
head the other is merging from. Scoping by lane is what makes two lanes at once safe.

```bash
bash "$GANTRY/skills/integrate/scripts/order_queue.sh" --base <BASE> --created 21:<epoch> --created 23:<epoch> 21=refs/integrate/integration/<date>/pr/21 23=refs/integrate/integration/<date>/pr/23
```

Pass `--created` from each PR's `CREATED:` epoch, so a rebased old PR is not treated as young. Pass
`--after <child>:<parent>` for any pair the candidate list reported as `STACKED_ON` — ancestry
usually shows it, and `--after` is what covers a parent that was force-pushed since.

It prints the stack relations, each item's size and age, the skips, the pairwise conflict matrix,
and the queue. It creates no commit and moves no ref.

**Compare each `ITEM:` sha against that PR's `HEAD_SHA`.** A difference means the PR moved between
listing and fetching — go back to stage 2 rather than planning against a head that no longer
exists.

On a **re-run**, also run the state script (stage 5's command) and fold it in: `integrated` items
leave the queue, `stale` items re-enter it, `unverified` items go to the front (their merge is in and
unproven, so it is gated before anything is added to it), a `STRAY_PRE:` ref is deleted before its
item is re-queued, and `rewritten` items are shown for a decision.

## Stage 4 — Checkpoint: the queue

**AskUserQuestion.** Nothing has been created yet. Show:

- the queue in order, each item with why it sits there (`isolated`, `overlapping`, `stacked`) and
  its CI class;
- every predicted conflict, with **both PRs' stated intent** beside it, because that is what the
  resolution will be made from;
- every skipped PR and its reason, in the script's words;
- on a re-run, what is already integrated, what is stale, and anything rewritten.

Ask: "Merge these N PRs in this order?" A "no" here costs nothing.

## Stage 5 — The lane

**Invoke `gantry:worktree integration/<date>`**, with the name stage 3 settled. Let it own the
branch, the fetch and entering the worktree.

**It picks its own parent, and that is the one thing it cannot be told.** `gantry:worktree` prefers
`develop`, then `origin/HEAD`, then `master`/`main`, and asks when the current branch is something
else — so under `--base <branch>` it can cut the lane from a branch this run is not integrating
into. If it asks which parent to use, the answer is `<BASE>`. Then check, rather than assume:

```bash
git rev-parse HEAD
```

```bash
git rev-parse origin/<BASE>
```

Three outcomes, and they are not the same problem:

- **HEAD equals the fresh `origin/<BASE>`** → right lane, current base. Go on.
- **HEAD equals the `BASE:` sha `order_queue.sh` printed, but `origin/<BASE>` has moved** → base
  moved while you were at the checkpoint. Re-run `order_queue.sh`, and re-ask stage 4 **only if** the
  queue, the conflicts or the skips changed.
- **HEAD is neither** → the lane was cut from the wrong parent. **Stop.** Do not merge anything into
  it and do not "fix" it by merging the base in: the lane would then carry every difference between
  that parent and `<BASE>`, and the PR would offer all of it for review. Say which branch it was cut
  from, and that the remedy is to remove the lane (`git worktree remove`) and re-run from `<BASE>`.

### The baseline gate, before `task.md` exists

```bash
bash "$GANTRY/lib/run_gates.sh" --strict
```

A red base makes every later red gate ambiguous, so it is proved first:

- `0` → go on.
- `1`+ → **stop.** The base itself is red. Nothing merged here could be blamed fairly.
- `2` → stop. The gate could not run.
- `3` → `NO-GATES` under `--strict`. **AskUserQuestion**: continue with no enforced checks (which
  goes in the PR body under *Not proven by this run*), or stop and add `.claude/gates.sh` first.
  This is the one place the strict default can be overridden, and only by you.

This runs **before** `task.md` is written, deliberately: the readiness hook arms on `task.md` plus
`status: implementing`, and a stop chosen here should not be blocked by it.

### Then write `task.md`

At the worktree root, not committed (`gantry:worktree` already excluded it):

```markdown
---
id: integration-<date>
title: Integrate PRs <numbers> into <BASE>
project: <repo>
branch: integration/<date>
base: <BASE>
mode: auto
status: implementing
---
```

with the queue as its *Context & goal*, one acceptance criterion — `run_gates.sh --strict` exits 0
on the final tree — an *Open questions* section saying `None.`, and a `## Skipped` section, which
is where a skip decided during the loop is written down so a later run and the PR body both find
it.

`status: implementing` arms the readiness hook where the repo has `.claude/gates.sh`, so a turn
cannot end on a red combined tree. **Before any deliberate stop, set `status: blocked` first** —
see `references/merge-loop.md`.

### On a re-run, act on the state before merging anything

```bash
bash "$GANTRY/skills/integrate/scripts/integration_state.sh" --base <BASE> 21=refs/integrate/integration/<date>/pr/21 23=refs/integrate/integration/<date>/pr/23
```

Route on `NEXT:` — `finish-merge`, `verify`, `merge-base`, `merge-items` — exactly as
`references/merge-loop.md` sets out. It is an order, not a menu.

## Stage 6 — The merge loop, one PR at a time

Full rules in `references/merge-loop.md`. The shape, per queued PR:

```bash
git update-ref refs/integrate/integration/<date>/pre/21 HEAD
```

```bash
git -c rerere.enabled=true -c merge.conflictStyle=zdiff3 merge --no-ff --no-commit refs/integrate/integration/<date>/pr/21
```

Resolve any conflict from both sides' intent. Then:

```bash
git -c rerere.enabled=true commit -m "integrate: merge #21 — <title>" -m "<one line per conflicted file, and how it was resolved>"
```

```bash
bash "$GANTRY/lib/run_gates.sh" --strict
```

Green → drop the pre-merge ref and take the next PR:

```bash
git update-ref -d refs/integrate/integration/<date>/pre/21
```

Red → a **separate** fix commit, then the gate again, at most twice. Still red → reset this merge
out, **delete the pre-merge ref**, record the skip in `task.md`'s `## Skipped`, and skip every queued
PR stacked on it. Exit `2` → stop, and it does not count as an attempt.

**Deleting that ref is part of the skip, not tidying.** Left behind, the state script reads it as a
merge whose gate never went green, so the next run sends a PR that was deliberately skipped back
into the fix loop for a merge that is no longer in the tree — and `NEXT:` never reaches `nothing`.

The settings ride on `git -c` rather than `git config`: a linked worktree's `git config` writes the
repository-wide file that every other checkout reads.

## Stage 7 — Docs: check and update the docs for the combined tree

Each source PR documented its own change alone, against the base it was cut from. The combined
tree is what the docs now have to describe, and the boring shared surfaces — a skill count, a
table, a flags list, a changelog — are exactly where two true-in-isolation edits add up to one
wrong number or two entries for one change. This stage reconciles the docs **on the lane**, before
the reviewer, so the reviewer reads the docs change together with the resolutions rather than
finding the drift afterwards.

On a fresh run `task.md` still says `status: implementing` from stage 5, and it stays so through
this stage: the readiness hook is wanted here as much as in the loop. **On a re-run, set it back to
`status: implementing` before anything else** — a resumed lane says `blocked`, `reviewed` or
`shipped`, and under any of those the hook is off.

### Collect what the PRs touched, or should have

```bash
git diff --stat origin/<BASE>..HEAD -- '*.md' docs/ README.md CHANGELOG.md
```

`origin/<BASE>`, which stage 2 fetched — a stale local `<BASE>` would list doc changes made on
the base as if a PR had made them. Then each included PR's `## What this change is for`, **re-read
here**, because a resumed run is usually a different session and nothing from stage 2 survives in
it:

```bash
gh pr view <n> --json body
```

A `CONTRACT:none` PR contributes its title and its diff, and the report says it had no stated
intent.

### Check the combined tree against the docs

The surfaces, **where the repo has them** — a surface the repo does not keep is nothing to check,
never something to create:

- `docs/SKILLS.md`: the skill-count line, the skills table, the shared-flags list. A count is the
  sum of what every included PR added, not either PR's number — the same arithmetic rule as a
  conflict in the loop, applied to a file that may have merged cleanly.
- `README.md`: every section that names a skill or a flag.
- `CHANGELOG.md`: one entry per included PR under the repo's unreleased heading, and no duplicate
  or contradictory entries now that the merges have met.

### Update, in one commit of its own

If nothing is off, make no commit and carry **no docs change needed** forward to the report and
the PR body. Otherwise, exactly one commit, separate from every merge and fix commit, so a reader
can tell what the merges did from what the docs needed. First make sure the hook's own log cannot
ride along — the readiness hook has been writing `.claude/artifacts/gate-hook.log` since `task.md`
was written in stage 5, and the exclude otherwise lands only at Publish:

```bash
bash "$GANTRY/lib/ensure_excluded.sh" .claude/artifacts/
```

Then stage the doc paths **explicitly** — each file this stage edited, by name, never `git add -A`,
and never a path the repo does not have, which `git add` refuses with nothing staged:

```bash
git add -- <each doc path this stage edited>
```

```bash
git commit -m "integrate: docs — <what was reconciled>" -m "<one line per surface, and the PR it is for>"
```

`integration_state.sh` reads back only `integrate: merge <token> ` subjects, so this one is inert
to a re-run.

### The gate, like after any other commit

```bash
bash "$GANTRY/lib/run_gates.sh" --strict
```

Red → a **separate** fix commit, staged the same way, then the gate again, at most twice:

```bash
git add -- <each doc path the fix touched>
```

```bash
git commit -m "integrate: fix docs — <why>"
```

Still red → set `status: blocked` and stop: the only thing that changed is the docs commit, and
the tree must not reach the reviewer or the PR red. There is no pre-merge ref and no reset here —
the docs commit is the lane's own, not a PR's. Exit `2` → stop, and it does not count as an
attempt.

### On a re-run

A resumed run arrives here from `NEXT:nothing` — including one that last stopped `blocked` on a red
docs gate, which nothing in git marks. Set `status: implementing`, then **run the gate first**,
before deciding anything: the lane's last gate result is not in this session. Red → the fix loop
above with a fresh budget of two, and the report says so. Then collect and check as on a fresh run.
An earlier `integrate: docs` commit is never amended:

```bash
git log --first-parent --format=%h%x20%s origin/<BASE>..HEAD
```

A second one is made only if something is still off, and the report lists each. A docs commit made
on a re-run goes on through review, the checkpoint and the push like any other — a lane that already
has a PR takes only the push in Publish, and the commit must not stay local with the report naming
its sha.

### The rules this stage keeps

- **Every command is flat**, as everywhere in this skill — `tests/cases/integrate_flat_commands.sh`
  scans this stage too.
- **Never touch a source PR's branch.** A docs gap that belongs to one PR is fixed on the lane,
  and that PR's author learns of it from the comment in Publish, not from an edit to their branch.
- **Never merge the integration PR.** That is still yours.

## Stage 8 — Review the resolutions, not just the diff

Set `status: implemented` first, because the reviewer's own stop would otherwise meet an armed
readiness hook.

Dispatch **one** reviewer (Agent): the repo's `.claude/agents/reviewer.md` if it defines one, else
`gantry-reviewer`. Do not write a new agent. Give it paths and commands, not contents:

```bash
git log --first-parent --format=%h%x20%s <BASE>..HEAD
```

```bash
git show --remerge-diff <merge-sha>
```

`--remerge-diff` shows exactly what the resolution changed against a mechanical merge, which is the
part no ordinary diff review ever sees. Also give it each `integrate: fix` commit **and the `integrate: docs`
commit from stage 7** — the docs reconciliation is part of the combined change it is reviewing —
plus the source PR numbers and their contracts, and ask specifically for what only appears when
PRs meet:

- two PRs adding the same helper under different names;
- a count, a table or a list updated twice;
- version bumps that disagree;
- something one PR deferred that another already fixed;
- a resolution that kept both sides' text but not both sides' behaviour.

**Verify every finding before acting on it.** An interaction defect gets a fix commit and a gate
run. A finding about a single PR's own content is **not yours to fix** — invoke `gantry:handover`
and let the source PR's author have it. Then set `status: reviewed`.

## Stage 9 — Checkpoint: the pull request

First re-read reality, because a source PR may have been pushed while the loop ran:

```bash
bash "$GANTRY/skills/integrate/scripts/list_candidates.sh" --base <BASE>
```

```bash
bash "$GANTRY/skills/integrate/scripts/integration_state.sh" --base <BASE> 21=refs/integrate/pr/21
```

Anything now `stale` is shown with the offer to merge the new commits first.

**AskUserQuestion**, with the included table (number, title, merge commit, conflicts y/n, gate
result), the skipped list with reasons, every resolution and its reasoning, the docs commit (or
that none was needed), and what the review found: "Push the lane, open the integration PR against `<BASE>`, and comment on the N included
PRs?"

## Stage 10 — Publish

Set `status: shipped` first — the push is next, and a status written after it would miss it.

```bash
bash "$GANTRY/lib/ensure_excluded.sh" .claude/artifacts/
```

Compose the body per `references/pr-body.md` into
`.claude/artifacts/integration-pr-body.md`, then let the checker decide whether it reads as prose:

```bash
bash "$GANTRY/scripts/check_pr_body.sh" .claude/artifacts/integration-pr-body.md
```

```bash
git push -u origin HEAD
```

```bash
gh pr create --base <BASE> --head integration/<date> --title "<title>" --body-file .claude/artifacts/integration-pr-body.md
```

The body file stays inside the checkout and is passed by a relative path, run from the worktree
root with no `cd` in the same command: a body file from outside the repository is an upload by
path, which a privileged-command gate asks a human about. Once the PR is open — or, on a lane that
already has one, once the push is done — remove it, so a later run never reads a stale body as its
own. If `gh pr create` failed, leave it: it is excluded from git, and the next run composes it
afresh.

```bash
rm -f .claude/artifacts/integration-pr-body.md
```

```bash
gh pr comment 21 --body "Included in the integration PR <url>, merged as <sha>. Nothing on this branch was changed."
```

One comment per **newly** included PR — a re-run does not comment again on a PR it commented on
before. If the lane already has a PR, the push is the whole of this stage, and then:

```bash
bash "$GANTRY/skills/ship/scripts/detect_state.sh" --base <BASE>
```

```bash
gh pr checks
```

## Stage 11 — Report

- The base, the lane branch, and the worktree path.
- **Included**: each PR, its merge commit, whether it conflicted, and its gate exit code.
- **Skipped**: each PR and the reason, in the words the script or the loop used.
- **Every conflict resolution** and what it was decided from.
- **Docs**: the `integrate: docs` commit, sha and subject, and what it reconciled — or
  `no docs change needed`.
- The gate: `--strict` or overridden, the baseline result, the exit code after each merge, and how
  many fix attempts were used.
- `HOOK:conditions-met` or `conditions-unmet` from `lib/detect_stage.sh` — and what that does not
  settle: the detector cannot see whether the hook is registered.
- Which reviewer ran, named plainly, and what it found.
- The `handover.md` path, if anything was handed back.
- The PR URL, and two things about it that are not obvious:
  **merge it with a merge commit** — a squash or rebase rewrites the commits, so no source PR's
  head reaches the base and none of them will be marked merged — and **a stacked child PR may stay
  open** even then, because its base branch is its parent's, which the integration merge never
  updates.

Be honest about anything skipped, unverified, or self-reviewed.
