# The merge loop

Detail behind stages 5 and 6 of `gantry:integrate`: how a resumed run picks up, how a conflict is
resolved, what a red gate costs, and the two guards that keep a bad merge from becoming permanent.

Read it before the first `git merge`.

## Contents

- Resuming: the order a re-run must act in
- One PR at a time
- Conflicts: resolving from intent
- The gate after every merge
- When the gate stays red
- Skips cascade to children
- Stopping on purpose, with the hook armed
- Base moved

## Resuming: the order a re-run must act in

`integration_state.sh` prints a `NEXT:` line. It is an order of operations, not a menu, because
each earlier state makes the later ones unreadable:

| `NEXT:` | What happened | What to do |
|---|---|---|
| `finish-merge` | `MERGE_HEAD` exists: a session died mid-conflict | **AskUserQuestion** first. Then `git merge --abort`, and reset to that PR's pre-merge ref if one is left. Re-queue the PR. |
| `verify` | A pre-merge ref survives on a merge that **is** in the tree: its gate never went green | Run the gate **before merging anything else**. Green: delete the ref. Red: it enters the fix loop with a fresh budget of 2, and the report says so. |
| `merge-base` | The base branch has moved | Merge base into the lane, then gate, before any PR. |
| `merge-items` | Nothing outstanding | Work the queue. |
| `nothing` | Everything queued is integrated | Go to the review stage, or to the report if the PR already exists. |

A **`STRAY_PRE:`** line is not one of those states. It is a pre-merge ref for something that is *not*
in the tree — the run died between writing the ref and finishing the merge, or a skip left it
behind. There is nothing to gate: delete the ref, then treat the PR as pending.

Every ref this loop writes is named after the lane's own branch —
`refs/integrate/<lane-branch>/pre/<label>`, and the PR heads under
`refs/integrate/<lane-branch>/pr/<n>`. `refs/` lives in the **common** git directory, shared by every
worktree, so two lanes sharing one `refs/integrate/pre/21` would mean each deleting the other's only
undo ref. The paths below spell the lane out for that reason.

A `rewritten` item is the one state that never resolves itself: the commits already merged are not
in the PR's history any more. **Ask.** Merging the new head on top leaves both tellings of the same
change in the tree, and neither the author nor the reviewer asked for that.

**None of this is read from the conversation.** A resumed run is usually a different session; the
lane's git history, its pre-merge refs and its `task.md` are the whole record.

## One PR at a time

```bash
git update-ref refs/integrate/integration/<date>/pre/21 HEAD
```

The pre-merge ref is the undo, and it is a ref rather than a remembered sha for the same reason
everything else here is: the session that needs it may not be the session that wrote it.

```bash
git -c rerere.enabled=true -c merge.conflictStyle=zdiff3 merge --no-ff --no-commit refs/integrate/integration/<date>/pr/21
```

- `--no-ff` because the merge commit **is** the record: it is what carries the resolution note, and
  what keeps the PR's own commits reachable so GitHub can mark it merged later.
- `--no-commit` so the message is written after the resolution is known, not before.
- `-c` rather than `git config`: in a linked worktree `git config` writes the repository-wide file,
  which every other checkout and every other lane then reads. Per-worktree config would need
  `extensions.worktreeConfig`, which is a repository-wide change to make a local one.
- `rerere` records each resolution, so a merge that is reset out and retried does not have to be
  resolved twice. A resolution it replays is still **read and listed** — it is a saved answer to
  the same textual conflict, not a verdict about this queue.
- `zdiff3` shows the base text alongside both sides, which is usually what makes an intent
  readable.

Then commit with the record in the message:

```bash
git -c rerere.enabled=true commit -m "integrate: merge #21 — <title>" -m "<conflicts>"
```

The subject shape is not cosmetic: `integration_state.sh` reads `integrate: merge <token> ` back to
find what was merged, and matches the whole prefix so `#2` cannot match `#21`.

The body lists **every conflicted file and one line on how it was resolved**, or says
`Conflicts: none`. That is where a reviewer and every later run learn what a resolution decided.

## Conflicts: resolving from intent

The two sides are not two texts. They are two PRs, each with a purpose you can read: a gantry PR
body states it under `## What this change is for`, and any PR has a title, a diff and its commits.

- **Never `--ours` or `--theirs` wholesale.** Both changes were wanted. Taking one side entire is
  how a merge silently reverts a PR that its own row says was included.
- **Never drop a hunk** because it looked redundant. If it is genuinely redundant — one PR already
  did what the other deferred — that is a finding for the review stage and a line in the merge
  message, not a quiet deletion.
- **The common cases are arithmetic, not judgment.** A count in a docs table that both PRs
  incremented is the sum, not either side's number. A list both extended keeps both entries. A
  table row order follows whatever the file already sorts by.
- **A version bump both PRs made is a real decision.** Take the higher one only when the change is
  additive both ways. Otherwise it is a question.
- **When the two intents do not settle it, ask** — AskUserQuestion, with what each option costs.
  Never a plain-text question: a question asked in prose ends the turn, and a turn that ends
  mid-merge meets the readiness hook on a tree full of conflict markers.

## The gate after every merge

```bash
bash "$GANTRY/lib/run_gates.sh" --strict
```

Every merge, no exceptions, and `--strict` even though this is a supervised skill: the whole point
is that PRs which ran no check of their own must not be integrated into a tree nobody checked
either. The exit codes are `run_gates.sh`'s own contract — `0` green, `1`+ a check failed, `2` the
gate could not run, `3` `NO-GATES` under `--strict`.

A red gate here belongs to **this PR or to its meeting with the ones before it**, and that is the
whole reason the loop merges one at a time. It is never attributed to the pile.

Green → `git update-ref -d refs/integrate/integration/<date>/pre/21`, and on to the next.

## When the gate stays red

A fix is a **separate commit**, never folded into the merge, so a reader can tell what the merge
did from what the combination needed:

```bash
git commit -m "integrate: fix #23 against #21 — <why>"
```

Then the gate again. **At most two fix attempts.** After that, the merge comes out:

```bash
git merge-base --is-ancestor origin/integration/<date> refs/integrate/integration/<date>/pre/21
```

```bash
git reset --hard refs/integrate/integration/<date>/pre/21
```

**The guard is not optional.** Reset only when the lane has no remote yet (`REMOTE:none`) or when
the remote tip is an ancestor of the pre-merge ref — that is, when nothing published is being
discarded. A published merge is never reset and never reverted: reverting it would leave the source
PR's commits reachable, so GitHub would still mark that PR merged while its change is gone. Stop
and ask instead.

Then delete the pre-merge ref, because the merge it guarded is gone:

```bash
git update-ref -d refs/integrate/integration/<date>/pre/21
```

**That deletion is part of the skip.** Left behind, the ref says "a merge went in and its gate never
went green", so the next run routes `NEXT:verify` for a merge that is not in the tree, sends a PR
the last run deliberately skipped back into the fix loop, contradicts `task.md`'s `## Skipped`, and
never lets `NEXT:` reach `nothing`.

Then record it, in `task.md`'s `## Skipped`, in the words that will reach the PR body:

```
- #23 — skipped: gate red after merge (2 fix attempts). Reset to <sha>.
```

Exit `2` is different. The gate could not run, which says nothing about the tree: **stop**, and do
not count it as an attempt.

## Skips cascade to children

A stacked child contains its parent's commits. Merging the child after skipping the parent puts the
parent's work in under the child's name, leaves the parent's row saying "skipped", and — because
its head then reaches the base — has GitHub mark the parent merged anyway.

So a PR skipped in the loop takes **every queued PR stacked on it**, transitively, with the reason
`parent-skipped:<n>`. `order_queue.sh` already does this for the skips it makes before the loop
starts; this is the same rule applied to the skips the loop makes itself.

## Stopping on purpose, with the hook armed

While `task.md` says `status: implementing`, a repo with `.claude/gates.sh` has the readiness hook
armed: it re-runs the gate at a stop and blocks a red one. That is wanted during the loop and
unhelpful when the skill has decided to stop *because* something is wrong.

So **set `status: blocked` before any deliberate stop** — a red baseline, a gate exit `2`, a
rewritten PR nobody has ruled on, a reset that cannot be made safely. The status is the record of
why the run ended, and it stops the hook from arguing with a decision the skill already made.

## Base moved

```bash
git -c rerere.enabled=true -c merge.conflictStyle=zdiff3 merge --no-ff origin/<BASE>
```

Merge base into the lane, then gate. **Never rebase the lane** — once it has been pushed, a rebase
breaks every merge-commit sha the PR body and the source-PR comments already name, and anyone who
pulled it has to recover by hand. A lane that has never been pushed is not a special case worth a
second procedure.
