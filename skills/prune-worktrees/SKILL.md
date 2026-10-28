---
name: prune-worktrees
description: Reviews every git worktree for staleness (no commits in 7+ days) or branches already merged into master/develop/main, shows a concise summary of each candidate's commit history, archives the chain artifacts it holds outside the repo, and removes the ones you approve. Use when the user types "/gantry:prune-worktrees", or asks to clean up, prune, or remove old or merged worktrees.
---

# gantry:prune-worktrees

Find worktrees that are stale (no commits in 7+ days) or whose branch is already merged into
`master`/`develop`/`main`, show a concise summary of each one's git state, and remove the ones the
user approves.

**Scope**: this skill removes worktree checkouts only. It never deletes branches, even fully
merged ones — branch cleanup is a manual follow-up the user can do themselves, listed at the end.

## Steps

### 1. Resolve the main repo root

```bash
MAIN_ROOT="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
```

Abort if not in a git repo. This holds even when invoked from inside a worktree.

### 2. Detect candidates

`$GANTRY` is this skill's plugin root — resolve it from this file's own location, the same way the
`skill` meta-skill does, rather than hardcoding a path.

```bash
bash "$GANTRY/skills/prune-worktrees/scripts/detect_candidates.sh"
```

The script fetches (`git fetch origin --prune`) before checking merge status, then classifies
every worktree. It never modifies worktrees itself — only the removal step in this file does that.

Output: a `FETCH:ok`/`FETCH:failed` line, then one pipe-delimited line per worktree —
`path|branch|status|days_idle|merged_into|head_sha|artifacts` — where `status` is one of `main`,
`current`, `bare`, `locked`, `dirty`, `candidate`, `keep`.

`artifacts` is the last field: the chain artifacts that worktree is holding, comma-separated —
`-` when it holds none, and **`?` when the worktree could not be read** (registered with git but
gone from disk, say). `?` is not `-`: it means *nobody knows*, and it must be reported as unknown
rather than as empty. The field is read from the filesystem, not from git, because `git status
--porcelain` cannot see an excluded file — which is the whole reason a worktree full of artifacts
reports clean and `git worktree remove` destroys it without a word.

**If `FETCH:failed`**: retry per the usual rules for a sandbox-caused failure if that looks like
the cause. If it still fails, say so prominently before continuing: merge-status below may be
stale, since it compares against whatever `origin/*` refs were last fetched. Never let this fail
silently.

### 3. Bucket the results

- `main`, `current` → not reported, never candidates (home base / the session's own worktree).
- `bare` → ignore.
- `locked` → collect as skipped (locked); note whether it would otherwise have qualified.
- `dirty` → collect as skipped (dirty); never destroy uncommitted work.
- `keep` → clean and recent — count only, no detail needed.
- `candidate` → the pruning candidates.

**The `artifacts` field never affects the bucket.** Every gantry worktree holds artifacts, so
treating them as a `dirty`-style skip would make this skill inert — they are *reported* so the
operator can see what is at stake, and *archived* in step 8 so the decision is not irreversible.
A `?` is reported as unknown, and it is not a bucket refusal either — but it is not consequence-free
either: `archive_artifacts.sh` cannot read a directory that is gone, so a `?` row's archive fails at
step 8 and that path is dropped from the removal list. Nothing is lost by that — there is nothing
left in the directory to lose — and step 9's `git worktree prune` is what clears a worktree git
still lists but whose directory has already vanished.

If there are zero candidates, skip straight to the Report — no need to ask anything.

### 4. Build a commit-titles summary per candidate

For each candidate, using its `branch` (or `head_sha` if detached):

```bash
git -C "$MAIN_ROOT" log -n 5 --format='%h %s (%cr)' <branch-or-head_sha>
```

Last-5-commits-on-the-tip, not a `base..branch` diff — a merged branch's diff against its base is
empty by definition (that's what "merged" means), so it wouldn't show anything useful there.

### 5. Print the summary (plain text, not a tool call)

One block per candidate: path (relative to `$MAIN_ROOT`), branch, reason(s) — `merged->master`,
`stale 19d`, or both — an `artifacts:` line carrying that row's seventh field verbatim (`none` for
`-`, `unknown` for `?`), and the commit lines from step 4. Also state the bucket counts from step 3
(checked / candidates / kept / locked / dirty) so the user sees the full picture, not just the
candidates.

### 6. Ask how to proceed

Use **AskUserQuestion**, one question:

- question: "Found N prune candidate(s) (stale >7d or merged into master/develop); M carry chain
  artifacts (archived before removal). How do you want to proceed?"
- options:
  1. "Review individually (Recommended)" — "Pick which of the N to remove, one by one"
  2. "Prune all N" — "Remove all N candidates now, archiving the artifacts of M of them"
  3. "Abort" — "Make no changes"

**The M is not decoration.** "Prune all N" routes straight to step 8 and never reaches step 7's
per-candidate options, so this question is the last thing the operator sees before anything is
removed. Count `artifacts` fields that are neither `-` nor `?`, and say separately how many are
`?` if any are.

"Abort" → stop, report nothing pruned. "Prune all N" → the full candidate list goes to step 8
directly; that choice is itself the confirmation, don't ask again. "Review individually" → step 7.

### 7. Individual review (only if chosen)

Split candidates into groups of ≤4. Each group is one multiSelect question in an **AskUserQuestion**
call (up to 4 questions per call = 16 candidates per call); if there are more than 16 candidates,
loop in further batches of 16.

Per group:
- header: "Batch X of Y"
- question: "Select worktrees to prune from this batch (leave unchecked to keep)"
- one option per candidate: `label` = branch name (or last path segment if detached),
  `description` = the reason string plus its artifacts (e.g.
  `merged->master · idle 42d · holds handover.md`), `preview` = that candidate's block from step 4
  with an `Artifacts:` line above the commit titles.

Nothing is pruned by default — a worktree is only removed if its option is checked. Accumulate
selections across every batch into the final list.

### 8. Archive, re-check, remove — one worktree at a time

**This loop is per-path, and that is load-bearing.** For each selected path, run all three commands
before moving on to the next path. Do not archive every worktree and then remove every worktree:
the safety re-check's entire value is that nothing happens between it and the removal, and copying
N worktrees in between reopens exactly the window it exists to close.

Per selected path, in this order. **Three separate blocks, deliberately** — each one's result
decides whether the next may run at all, so they must not be run as one call. Nothing below is a
command you may queue ahead of reading the one before it.

1. **Archive.** The artifacts are excluded from git, which is precisely why `git worktree remove`
   deletes them with rc 0 and no warning — and `handover.md` is the record of what the change
   deliberately did not do. The script copies whatever the worktree holds to
   `~/.claude/sessions/<repo-slug>/worktrees/<date>-<branch-slug>-<sha8>/`, outside every repo, and
   prints `ARCHIVE=<path>` plus a `COPIED=` line per item. Take `<branch>` and `<head_sha>` from
   that candidate's row; pass the branch verbatim, `-` included.

   ```bash
   bash "$GANTRY/lib/archive_artifacts.sh" "<path>" "<branch>" "<head_sha>"
   ```

   - Exit **0** → continue. `ARCHIVE=-` means there was nothing to copy, which is a success: a
     worktree holding no artifacts must stay prunable.
   - **Non-zero** → **drop that path from the removal list** and report it, the same shape as the
     became-dirty rule below. Nothing was recovered, so nothing may be destroyed. A row whose
     `artifacts` field was `?` lands here: the directory is gone, so there is nothing to copy *and*
     nothing to remove — step 9's `git worktree prune` is what clears it. Report it as already
     vanished rather than as a failed archive.
2. **Safety re-check**, only if the archive passed.

   ```bash
   git -C "<path>" status --porcelain
   ```

   If this is now non-empty (something changed since detection while the user was answering), drop
   that path and warn that it was skipped because it became dirty in the meantime.
3. **Remove**, only when both of the above passed.

   ```bash
   git -C "$MAIN_ROOT" worktree remove "<path>"
   ```

### 9. Prune the administrative files

Once, after all removals:

```bash
git -C "$MAIN_ROOT" worktree prune
```

Do not delete branches — not even fully merged ones. That's a manual follow-up, not something this
skill does.

## Report

- What was removed: path and branch for each, **and its archive path** — or "no artifacts" where
  the archive reported `ARCHIVE=-`. A removal whose artifacts went somewhere the operator cannot
  name is the one outcome this report must never produce.
- What was skipped and why: locked, dirty (at detection or at the safety re-check), **its archive
  step failed** (say which file could not be copied, from the script's stderr), or not selected
  during individual review.
- Branch names that are now unreferenced by any worktree and were merged, as an FYI, with the
  manual command to delete them (`git branch -d <branch>`) — not run automatically.
- Any warnings, e.g. a failed fetch and what that means for the merge-status shown.
