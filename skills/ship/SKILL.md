---
name: ship
description: Advances the current branch one clean step closer to a merged PR, doing only what isn't done yet — commits outstanding changes, pushes to the upstream, opens a pull request, and once the PR exists and is up to date, reports its status and waits. Idempotent — it detects the stage and picks up from there, so it's safe to run repeatedly. Pass --no-pr to stop after the push without opening a PR. Use when the user types "/gantry:ship", or asks to ship, to commit and push, to open a PR for this branch, or to "get this out for review". Refuses to run on the repo's default branch.
argument-hint: [--no-pr] [--base <branch>]
allowed-tools: Bash, Read
---

# gantry:ship

Move the current branch to the next stage on the path **commit → push → open PR → wait**, doing
only the stages that aren't done yet. Run it once and it advances as far as it can in one go; run
it again later and it picks up wherever the branch now sits.

Typing `/gantry:ship` **is** the go-ahead to commit, push, and open the PR — don't ask for
confirmation stage by stage. Do still stop on the guards below (default branch, diverged branch,
nothing to ship). This skill runs in any repo, so follow *that* repo's conventions, not gantry's.

**`--no-pr`**: if `$ARGUMENTS` contains `--no-pr`, run commit → push only. Skip stage 4 entirely
and treat the push as the finish line — after pushing, go straight to the report and note the PR
was intentionally not opened. This is the mode `/gantry:auto --no-pr` passes through.

**`--base <branch>`**: if `$ARGUMENTS` names a base branch, pass it straight through to the
detector (below) so it overrides base detection, and open the PR against it. Use it when the repo
integrates somewhere other than what detection would pick. An override that names a branch which
doesn't exist is ignored (the detector warns and auto-detects); a malformed `--base` with no value
is a usage error (the detector exits non-zero). `/gantry:auto --base <branch>` passes through.

## Steps

### 1. Detect the stage

`$GANTRY` is this skill's plugin root — resolve it from this file's own location, the same way the
`status` and `prune-worktrees` skills do, rather than hardcoding a path.

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
- `commit` → go to step 2, then flow on through push and PR.
- `push` → skip to step 3.
- `pr` → skip to step 4.
- `done` → skip to step 5.

Completing one stage lands you at the top of the next, so once you enter at the routed stage,
continue straight down 2 → 3 → 4 → 5 without re-detecting — except re-run the script once after
committing and pushing if you want to reconfirm `PR` and `AHEAD` before opening the PR.

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

### 3. Push

```bash
git push -u origin HEAD     # when UPSTREAM was NONE (first push of this branch)
git push                    # when an upstream already exists and AHEAD > 0
```

If the push is rejected because the remote moved, stop and report it — let the user integrate
(`git pull --rebase`) rather than force-pushing.

### 4. Open the PR

Skip this stage entirely if `--no-pr` was given — the push was the finish line. Go straight to the
**Report** (not step 5, which reads a PR that doesn't exist) and note the PR was intentionally not
opened.

Otherwise, only when `BASE` differs from `BRANCH` and there are commits over `BASE` (the detector's
`no-diff` guard already caught the empty case). If `GH` was `missing` or `unauth`, the commit and push still
happened — report that, print the manual `gh pr create` command, and stop.

Compose from the branch's commits rather than a bare `--fill`:

```bash
gh pr create --base "<BASE>" --head "<BRANCH>" --title "<title>" --body "<body>"
```

Title = the change in one line; body = a short what/why, bulleting the commits when there are
several. Report the PR URL it prints.

### 5. Done — report and wait

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

State what actually happened this run — which stages ran (committed / pushed / opened PR), the
commit subject, the PR URL, and the terminal status. If a guard stopped it (on the default branch,
diverged, nothing to ship, gh unavailable), say which and what the user should do next. Be honest
about anything skipped or unverified.
