---
name: ship
description: Advances the current branch one clean step closer to a merged PR, doing only what isn't done yet — commits outstanding changes, reviews them with /code-review unless the review is skipped, pushes to the upstream, opens a pull request, and once the PR exists and is up to date, reports its status and waits. Idempotent — it detects the stage and picks up from there, so it's safe to run repeatedly. Pass --no-pr to stop after the push without opening a PR, --draft to open the PR as a draft, or --reviewed to skip the review when one already ran. Use when the user types "/gantry:ship", or asks to ship, to commit and push, to open a PR for this branch, or to "get this out for review". Refuses to run on the repo's default branch.
argument-hint: [--no-pr] [--draft] [--reviewed] [--base <branch>]
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Skill
---

# gantry:ship

Move the current branch to the next stage on the path **commit → push → open PR → wait**, doing
only the stages that aren't done yet. Run it once and it advances as far as it can in one go; run
it again later and it picks up wherever the branch now sits.

Typing `/gantry:ship` **is** the go-ahead to commit, push, and open the PR — don't ask for
confirmation stage by stage. Do still stop on the guards below (default branch, diverged branch,
nothing to ship). This skill runs in any repo, so follow *that* repo's conventions, not gantry's.

**`--no-pr`**: if `$ARGUMENTS` contains `--no-pr`, run commit → push only. Skip stages 3 and 5
entirely and treat the push as the finish line — after pushing, go straight to the report and note
the PR was intentionally not opened, and that the review was skipped with it. This is the mode
`/gantry:auto --no-pr` passes through.

**`--reviewed`**: the change has already been reviewed; skip stage 3. Both drivers pass it, because
the chain runs `/gantry:review` as its own phase and a second review here would let `--fix` apply
findings that phase deliberately deferred. Pass it by hand when you have just reviewed the diff
yourself, or when re-running ship after it stopped part-way (see stage 3). It is an assertion that
a review happened, so it is a flag rather than something inferred — see stage 3 for why the
`status:` in `task.md` is deliberately not consulted.

**`--base <branch>`**: if `$ARGUMENTS` names a base branch, pass it straight through to the
detector (below) so it overrides base detection, and open the PR against it. Use it when the repo
integrates somewhere other than what detection would pick. An override that names a branch which
doesn't exist is ignored (the detector warns and auto-detects); a malformed `--base` with no value
is a usage error (the detector exits non-zero). `/gantry:auto --base <branch>` passes through.

**`--draft`**: open the pull request as a draft (`gh pr create --draft`). Use it when nobody has
reviewed the change live — which is why `/gantry:auto-unattended` always passes it. A draft doesn't
request reviewers, so it says "this is finished but unwatched" rather than "please look now". It
only affects stage 5; with `--no-pr` it does nothing.

## Steps

### 1. Detect the stage

`$GANTRY` is this skill's plugin root — resolve it from this file's own location, the same way the
other gantry skills do, rather than hardcoding a path.

```bash
bash "$GANTRY/skills/ship/scripts/detect_state.sh"                 # normal
bash "$GANTRY/skills/ship/scripts/detect_state.sh" --base <branch> # when --base was given
```

One read-only pass. It prints `BRANCH`, `BASE` (the PR base = repo default branch), `UPSTREAM`,
`AHEAD`/`BEHIND` vs upstream, `AHEAD_OF_BASE` (commits not yet in base), `DIRTY`, `ON_DEFAULT`,
`GH` (`ok`/`missing`/`unauth`), `PR` (`none`, or number + url + state + mergeable + reviewDecision),
and a final `STAGE:` — the entry point. Route on `STAGE`:

- `not-a-repo` / `detached` → nothing to ship; say so and stop.
- `on-default` → the branch **is** the base; you can't open a PR against itself. Stop and suggest
  starting a branch first (e.g. `/gantry:worktree <name>`). Don't commit onto the default branch.
- `behind` → the branch has diverged from its upstream (ahead **and** behind). Stop; tell the user
  to integrate first (`git pull --rebase`) and re-run. Never force-push to resolve this.
- `no-diff` → clean and pushed but no commits over `BASE` — there's nothing to open a PR for. Report
  and stop.
- `commit` → go to stage 2, then flow on through review, push, and PR.
- `push` → skip to stage 3.
- `pr` → skip to stage 3. The branch is already pushed, but the PR has not been opened, so the
  review still has somewhere useful to land.
- `done` → skip to stage 6. The PR already exists; there is nothing left to review before it.

Completing one stage lands you at the top of the next, so once you enter at the routed stage,
continue straight down without re-detecting — **with one exception: stage 3 can create a commit,
and if it does, you must re-run the script before continuing.** Everything after it branches on
`AHEAD` and `DIRTY`, and deciding from a read taken before the review would push the wrong thing,
or nothing at all.

### 2. Commit

Look before writing the message: `git status` and `git diff` (or `git diff --staged`).

- **Respect intentional staging.** If anything is already staged, commit exactly what's staged.
  Otherwise stage everything with `git add -A` and commit that.
- **One coherent change.** If the outstanding work is clearly several unrelated changes, don't bury
  them in one "ship" commit — pause and ask how to split it. A quick, coherent diff needs no such
  pause.
- **Message**: a concise imperative subject, plus a short body if the change warrants it. Match the
  repo's recent `git log` style, including whether it uses commit trailers — some repos do, some
  (like gantry) deliberately don't. Follow the ambient convention.

```bash
git commit -m "<subject>"        # add -m for a body paragraph if warranted
```

### 3. Review the change

The last point at which a fix is still cheap. Skip it and say which of these applied:

- **`--no-pr`** — the caller asked for commit → push and nothing else. Be honest about the trade in
  the report: the push still happens, so `--no-pr` pushes code this stage did not read. It is the
  one path where ship's own review is skipped and something still leaves the machine.
- **`--reviewed`** — a review already ran. The drivers always pass this, because the chain runs
  `/gantry:review` as its own phase.

Otherwise, invoke `/code-review` over the branch diff, **naming an effort level**:

```
/code-review high --fix
```

Name the level explicitly. With none given it reuses whatever was typed last in the session, which
makes two runs of this stage incomparable for a reason that has nothing to do with the diff.

**Invoke it rather than survey for it.** If the invocation errors, `/code-review` is unavailable —
report that **with the cause** and continue to the push. A review is advice here; a missing reviewer
never blocks a ship. The gate is what blocks.

This is why this skill's `allowed-tools` carries `Write`, `Edit`, `Grep` and `Glob` even though ship
itself writes no artifact: frontmatter *restricts* what is permitted while the skill is active, so
`--fix` cannot apply a single byte through a skill that has not allowed the tools it edits with. A
review that cannot write reports as a clean no-op, which is indistinguishable from a diff with
nothing wrong in it.

Then:

1. **If `--fix` changed nothing, you are done with this stage.** No commit, no gate run. This is the
   common case and it stays cheap.
2. **If it did change something**, commit those edits on their own:

   ```bash
   git add -A && git commit -m "Apply review findings"
   ```

   Separately from stage 2's commit, so the review's edits stay legible as review edits rather than
   folded into the change being reviewed.
3. **Then re-run the gate**, because a fix made after the gate went green is unproven code:

   ```bash
   bash "$GANTRY/lib/run_gates.sh"
   ```

   Same contract as `/gantry:implement`: `0` green · `1`+ red · `2` the gate could not run.
   **Red stops the ship** — no push, no PR. Report the exit code and what failed.

   Note what a `0` does and does not prove here. Ship runs the gate **without `--strict`**, so a
   repo where no checks are detected exits `0` rather than the `3` that `--strict` would give.
   In that repo the review's edits are pushed **unproven** — nothing ran over them. Say so in the
   report rather than reporting a green gate; "the gate passed" and "there was no gate" are not
   the same result, and this is the one stage that can push code no check has seen.
4. **Re-run `detect_state.sh`** before continuing, since you just committed.

**Why `--fix` here, when `/gantry:review` forbids it.** That skill refuses `--fix` because its
triage step weighs every finding against `task.md`'s *Out of scope*, and `--fix` would apply
findings the contract excludes. That reasoning does not transfer: this stage exists for the caller
who typed `/gantry:ship` on a change with no contract on disk and no triage step to protect, and
the two never both run — `--reviewed` guarantees it. Do not import review's triage procedure here;
if a change needs triage, it needs `/gantry:review`.

**Why the guard is a flag and not `task.md`'s `status:`.** Both drivers set `status: shipped`
*before* invoking ship, for an unrelated reason — so a status test would be satisfied by something
that was not a review. And a task left at `reviewed` from an earlier run, then edited further and
shipped again, would skip review of genuinely unreviewed code. A flag is written down; a status is
inferred.

Note for the report: whether this stage ran, and **how many files `--fix` touched**. Do not report a
findings tally — nothing here establishes that a reviewed-versus-applied count is available, and an
invented number is worse than none.

### 4. Push

```bash
git push -u origin HEAD     # when UPSTREAM was NONE (first push of this branch)
git push                    # when an upstream already exists and AHEAD > 0
```

Take `UPSTREAM` and `AHEAD` from the **most recent** detector read — stage 3 may have committed
since the first one.

If the push is rejected because the remote moved, stop and report it — let the user integrate
(`git pull --rebase`) rather than force-pushing.

### 5. Open the PR

Skip this stage entirely if `--no-pr` was given — the push was the finish line. Go straight to the
**Report** (not stage 6, which reads a PR that doesn't exist) and note the PR was intentionally not
opened.

Otherwise, only when `BASE` differs from `BRANCH` and there are commits over `BASE` (the detector's
`no-diff` guard already caught the empty case). If `GH` was `missing` or `unauth`, the commit and push still
happened — report that, print the manual `gh pr create` command, and stop.

Compose from the branch's commits rather than a bare `--fill`:

```bash
gh pr create --base "<BASE>" --head "<BRANCH>" --title "<title>" --body "<body>"
gh pr create --base "<BASE>" --head "<BRANCH>" --title "<title>" --body "<body>" --draft   # --draft
```

Title = the change in one line; body = a short what/why, bulleting the commits when there are
several. Report the PR URL it prints.

### 6. Done — report and wait

The branch is fully shipped: PR open, nothing left to push. Pull the current status so "wait" is
informed, not blind:

```bash
gh pr view --json url,state,mergeable,reviewDecision,statusCheckRollup
gh pr checks    # CI state, if there are checks
```

Report the PR URL, review decision, mergeability, and check status, and that there's nothing to do
but wait for review/CI. If checks are failing or the PR is blocked, say so plainly — that's the one
thing worth flagging here.

## Report

State what actually happened this run — which stages ran (committed / reviewed / pushed / opened
PR), the commit subject, the PR URL, **whether the PR is a draft or ready for review**, and the
terminal status.

For the review stage: whether it ran or was skipped and why, how many files `--fix` touched, and
the gate's exit code if the fixes made one necessary. If `/code-review` was unavailable, say so
**with the cause** — "unavailable" with no cause is how a silent downgrade hides.

If a guard stopped it (on the default branch, diverged, nothing to ship, gh unavailable), say which
and what the user should do next. **When a run stops after the review but before the PR** — the
`gh missing`/`unauth` case is the common one — tell the user to re-run with `--reviewed`. Ship
records nothing, so a bare re-run reviews and edits an already-pushed branch a second time.

Be honest about anything skipped or unverified.
