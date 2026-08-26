---
name: prune-worktrees
description: Reviews every git worktree for staleness (no commits in 7+ days) or branches already merged into master/develop/main, shows a concise summary of each candidate's commit history, and removes the ones you approve. Use when the user types "/gantry:prune-worktrees", or asks to clean up, prune, or remove old or merged worktrees.
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
`path|branch|status|days_idle|merged_into|head_sha` — where `status` is one of `main`, `current`,
`bare`, `locked`, `dirty`, `candidate`, `keep`.

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
`stale 19d`, or both — and the commit lines from step 4. Also state the bucket counts from step 3
(checked / candidates / kept / locked / dirty) so the user sees the full picture, not just the
candidates.

### 6. Ask how to proceed

Use **AskUserQuestion**, one question:

- question: "Found N prune candidate(s) (stale >7d or merged into master/develop). How do you want
  to proceed?"
- options:
  1. "Review individually (Recommended)" — "Pick which of the N to remove, one by one"
  2. "Prune all N" — "Remove all N candidates now"
  3. "Abort" — "Make no changes"

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
  `description` = the reason string (e.g. `merged->master · idle 42d`), `preview` = that
  candidate's commit-titles block from step 4.

Nothing is pruned by default — a worktree is only removed if its option is checked. Accumulate
selections across every batch into the final list.

### 8. Safety re-check

For every selected path, immediately before removing anything:

```bash
git -C "<path>" status --porcelain
```

If this is now non-empty (something changed since detection while the user was answering), drop
that path from the removal list and warn that it was skipped because it became dirty in the
meantime.

### 9. Remove

For each remaining selected path, in order:

```bash
git -C "$MAIN_ROOT" worktree remove "<path>"
```

Then once, after all removals:

```bash
git -C "$MAIN_ROOT" worktree prune
```

Do not delete branches — not even fully merged ones. That's a manual follow-up, not something this
skill does.

## Report

- What was removed: path and branch for each.
- What was skipped and why: locked, dirty (at detection or at the safety re-check), or not
  selected during individual review.
- Branch names that are now unreferenced by any worktree and were merged, as an FYI, with the
  manual command to delete them (`git branch -d <branch>`) — not run automatically.
- Any warnings, e.g. a failed fetch and what that means for the merge-status shown.
