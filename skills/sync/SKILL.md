---
name: sync
description: Returns you to the project's base branch and brings everything up to date — refuses if the tree has uncommitted changes, fetches with prune, resolves the base branch (an optional external profile resolver first, then the same detection gantry:ship uses), checks it out, fast-forwards it, reports which worktrees and local branches are now fully merged, and hands off to gantry:prune-worktrees to remove them. Never stashes, merges, rebases, or resets on its own. Use when the user types "/gantry:sync", or says "switch to develop and update", "merged, switch to master and update", "update the branch", or asks to get back to the base branch after a merge.
argument-hint: [base-branch]
allowed-tools: Bash, Read, Skill, AskUserQuestion
---

# gantry:sync

Counterpart to `gantry:worktree`: that skill opens a lane, this one closes the lanes a merge just
made dead and puts the main checkout back on the base branch. One invocation: fetch with prune,
resolve and check out the base, fast-forward it, report which worktrees became prunable, hand
off to `gantry:prune-worktrees`.

Everything below runs against `$MAIN_ROOT` via `git -C`, **except Stage 3's call into
`detect_state.sh`**, which takes no `-C` and reads whatever branch and working tree the current
shell is sitting in — see Stage 3 for what that means in practice. **`gantry:sync` never changes the
session's directory or the current worktree's branch** — "switch to develop" means the main
checkout ends up on the base, not the worktree you're sitting in. `$GANTRY` is this skill's plugin
root — resolve it from this file's own location, the way `status` and `ship` do, never a
hardcoded path.

## Stage 0 — Locate

```bash
MAIN_ROOT="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
CURRENT_WT="$(git rev-parse --show-toplevel)"
```

Not a git repo → say so and stop. `$MAIN_ROOT` resolves correctly from inside a worktree, same
as `gantry:prune-worktrees` step 1.

## Stage 1 — Refuse to lose work

```bash
git -C "$MAIN_ROOT" status --porcelain
```

Empty output → continue to Stage 2. **Any** output → stop, print the block below verbatim
(substituting the real values), and run **nothing** afterwards — no fetch, no checkout, no
`detect_state.sh`, no `detect_candidates.sh`:

```
gantry:sync stopped: <MAIN_ROOT> has uncommitted changes.

<the `git -C "$MAIN_ROOT" status --short` output>

Nothing was fetched, checked out, merged, or stashed.
Deal with the changes first, then re-run /gantry:sync:
  /gantry:ship                     — commit and push what's here
  git stash push -u -m pre-sync — stash them yourself, if that is what you want
```

**Do NOT run `git stash`, `git stash push`, `git checkout -- .`, `git restore`, `git clean`, or
`git reset` on the operator's behalf — not before asking, and not after. Naming the stash command
in the refusal text is the offer; running it is not the skill's to do. On a dirty tree the only
move is to stop.**

This checks `$MAIN_ROOT`, the tree `git checkout` will actually move — not necessarily
`$CURRENT_WT`. A dirty current worktree that is not `$MAIN_ROOT` is **not** a refusal (that tree
is never written to), but note it in the final report: `detect_candidates.sh` will classify it
`dirty` and `gantry:prune-worktrees` will skip it.

## Stage 2 — Fetch

```bash
git -C "$MAIN_ROOT" fetch --prune origin
```

A failed fetch is announced prominently and never silent. Against an HTTPS remote it can fail
with `could not read Username for 'https://github.com': Device not configured` — a sandboxed
credential-helper failure worth one retry unsandboxed (same register as `gantry:worktree` step 5).
If it still cannot be made to succeed, **stop before Stage 4's checkout**: fast-forwarding
against stale refs is exactly the silent staleness this skill exists to prevent.

## Stage 3 — Resolve the base

**Optional: an external profile resolver.** gantry can ask an external tool for the project's
`BASE_BRANCH` before falling back to detection. The reference implementation is
`gantry-profile` — a resolver you provide yourself. **gantry
does not ship it and does not require it, and its absence is the normal case, never a warning.**
To wire your own, put an executable named `gantry-profile` on `PATH` supporting the two calls
and exit codes below; see `docs/ARCHITECTURE.md` § "The one external hook".

**Reader resolution.** `command -v gantry-profile`, else `$HOME/.local/bin/gantry-profile`,
else there is no profile reader on this box — skip straight to the `detect_state.sh` call below
with no `--base`.

**Project resolution.** `$GANTRY_PROJECT` if set, else
`gantry-profile --task-project "$CURRENT_WT/task.md"`.

`gantry-profile --task-project` exits 1 with empty stdout when there is no `task.md` or no
`project:` key — the ordinary case for a repo with no profile resolver at all. **If `$PROJECT`
comes back empty, skip the lookup entirely: no `gantry-profile "$PROJECT" BASE_BRANCH` call, no
`PROFILE_BASE`, and no warning.** An empty project is not an rc-2 case and must never be forced
through the lookup below just to see what happens to it — the field-name validation in
`gantry-profile` would reject an empty argument and produce a broken-profile-looking rc 2 for a
repo that simply has no profile, which contradicts the "absence of a profile is never a warning"
rule below and must not be allowed to happen.

**The lookup**, only when `$PROJECT` is non-empty:

```bash
gantry-profile "$PROJECT" BASE_BRANCH
```

Read its exit code: **rc 0 + non-empty stdout → use it as `PROFILE_BASE`.** rc 1 (field absent)
or rc 3 (no such project) → no profile base; stay silent — those are normal, expected outcomes
for the majority of repos with no profile resolver at all, and the absence of a profile is never
a warning. rc 2 → mention it once in the report; it means a broken profile or an unknown field,
worth a line but not worth stopping over.

**The `--base` slot** is filled by the first of: an explicit `/gantry:sync <base-branch>` argument
(`$ARGUMENTS`), then `PROFILE_BASE`, then nothing.

An explicit argument gets one extra check that a profile value does not: **before** handing it to
`detect_state.sh`, verify it resolves —
`git -C "$MAIN_ROOT" show-ref --verify --quiet "refs/remotes/origin/$ARGUMENTS"` or
`refs/heads/$ARGUMENTS`. If neither exists, **stop** — do not fall through to detection:

```
gantry:sync stopped: base branch '<ARGUMENTS>' not found on origin or locally.
Check the spelling, or omit the argument to let sync resolve the base itself.
```

This is deliberately asymmetric with `PROFILE_BASE`, which is *not* pre-checked and is passed
straight through to `detect_state.sh --base` below: an operator who just typed
`/gantry:sync <base-branch>` gets a hard stop on a typo rather than a silent switch to whatever
`detect_state.sh` would have picked instead, while a `BASE_BRANCH` sitting in a profile is stored
config that can go stale on its own schedule, and `detect_state.sh`'s existing fall-through (one
stderr line, then detection) is the right amount of leniency for that case:

```bash
bash "$GANTRY/skills/ship/scripts/detect_state.sh" [--base "$ARGUMENTS_or_PROFILE_BASE"]
```

Read the `BASE:<name>` line from its stdout — nothing else about base resolution belongs here;
`detect_state.sh` already carries `gantry:ship`'s own precedence and validates an override
(`base_exists`) before trusting it, falling through to detection with one stderr line if the
named branch doesn't exist on origin or locally. By the time a value reaches this call it is
either `PROFILE_BASE` (unvalidated, may still fall through here) or an `$ARGUMENTS` value already
proven to exist above.

One factual note: `detect_state.sh` skips `develop` as a candidate when the *current* branch is
already `develop`, because its question is "what do I PR into" and a branch can't PR into
itself. This call has no `-C`, so "current" means `$CURRENT_WT` — the worktree you invoked
`/gantry:sync` from, which is not necessarily `$MAIN_ROOT` and can be on a different branch than it.
With a profile value this never bites — the override is checked first. Without one, running
`/gantry:sync` from a worktree that is itself on `develop` resolves the base to the remote default
instead, even if `$MAIN_ROOT` is on some other branch. Report the base and how it was resolved
either way; this is not special-cased.

Record `$BASE` and the resolution source (argument / profile / detection, and if detection,
which rule fired) for the Report.

## Stage 4 — Checkout

```bash
OLD_SHA="$(git -C "$MAIN_ROOT" rev-parse "$BASE" 2>/dev/null || true)"
git -C "$MAIN_ROOT" checkout "$BASE"
```

Capture `OLD_SHA` first (empty if `$BASE` has no local ref yet) so the Report can give the real
`old..new` range.

- **No local `$BASE`** — the checkout above creates it from `origin/$BASE` by DWIM with a single
  remote, and Stage 5's fast-forward is then a no-op. If DWIM fails (several remotes carry the
  name), use `git -C "$MAIN_ROOT" checkout -b "$BASE" --track "origin/$BASE"`.
- **No `origin/$BASE`** (local-only base) — the checkout still succeeds against the local ref;
  skip Stage 5's fast-forward, say the base is local-only and may be stale, continue to Stage 6.
- **`$BASE` is already checked out in another worktree** — `git -C "$MAIN_ROOT" checkout "$BASE"`
  fails with `already checked out at <path>`. Find it with
  `git -C "$MAIN_ROOT" worktree list --porcelain`, matching `branch refs/heads/$BASE`. If that
  checkout is clean, run Stage 5's fast-forward there instead
  (`git -C <that-path> merge --ff-only "origin/$BASE"`) and say plainly where the base lives. If
  it is dirty, stop with Stage 1's refusal wording pointed at that path instead of `$MAIN_ROOT`.
  This mirrors `gantry:worktree` step 5 ("base already checked out elsewhere") rather than
  inventing a new rule.

## Stage 5 — Fast-forward

```bash
git -C "$MAIN_ROOT" merge --ff-only "origin/$BASE"
```

(Or at the other worktree's path, if Stage 4 found the base checked out elsewhere.)

Non-zero exit → **stop**. Report the divergence with counts from

```bash
read -r ORIGIN_ONLY LOCAL_ONLY < <(git -C "$MAIN_ROOT" rev-list --left-right --count "origin/$BASE...$BASE")
```

`--left-right` on `origin/$BASE...$BASE` prints the left (origin-only) count first and the right
(local-only) count second — `ORIGIN_ONLY LOCAL_ONLY`, in that order, not the reverse. Use them by
name, not position, so the report cannot end up with the two swapped:

```
gantry:sync stopped: <base> has diverged from origin/<base> — a fast-forward is not possible.
  local  <base>         <sha>   (LOCAL_ONLY commit(s) not on origin)
  remote origin/<base>  <sha>   (ORIGIN_ONLY commit(s) not local)
Nothing was merged, rebased, reset, or force-pushed. Sort this out by hand, then re-run /gantry:sync.
```

**No `git merge` without `--ff-only`, no `git rebase`, no `git reset` (`--hard` or otherwise), no
`git push --force`/`--force-with-lease`, and no bare `git pull` (it can merge). Divergence is a
fact for the operator to see, not a state for this skill to repair.**

Two cases that are not divergence: `Already up to date.` (rc 0, no movement) → report says
"already current"; a local-only base (Stage 4) → this stage is skipped entirely, not attempted.

## Stage 6 — What became prunable

```bash
bash "$GANTRY/skills/prune-worktrees/scripts/detect_candidates.sh"
```

Runs from anywhere in the repo (it resolves `$MAIN_ROOT` itself). Parse the `FETCH:` line and
the pipe-delimited `path|branch|status|days_idle|merged_into|head_sha` rows — the same script
`gantry:prune-worktrees` uses, so the two never disagree about what "merged" means.

**The double fetch is deliberate.** Stage 2 fetched because the checkout and fast-forward depend
on fresh refs; this script fetches again itself. Removing Stage 2's fetch to save the round trip
would fast-forward against stale refs — do not "optimise" it away. By the time this stage runs,
Stage 2's fetch has already succeeded — an unrecoverable Stage 2 failure stops before Stage 4, so
this stage is never reached in that case. The only fetch that can fail here is this script's own:
if it prints `FETCH:failed`, say so and carry `prune-worktrees` step 2's warning that merge status
may be stale.

**Before splitting rows into buckets, check whether `merged_into` can even speak to `$BASE`.**
`detect_candidates.sh` only tests ancestry against `develop`, `master`, and `main` — it has no way
to report a merge into any other branch. If the base resolved in Stage 3 is not one of those
three (an explicit `--base trunk`, a `BASE_BRANCH` pointing at a release branch, or detection
landing elsewhere), say so plainly in the report: **merge classification is unavailable for base
`<base>`; the prunable report below is incomplete and may be missing worktrees that are actually
merged.** Do not fall silently into "nothing became prunable" in that case — an honest "I can't
tell you this for `<base>`" beats a false negative.

Split the `candidate` rows into three buckets:

1. **Merged into `<base>`** (the base resolved in Stage 3, present in `merged_into` — only
   possible when `<base>` is `develop`, `master`, or `main`, per the caveat above) — these are the
   ones this sync just made dead. Lead the report with them.
2. **Merged into another branch, not `<base>`** — `merged_into` is non-`-` but does not contain
   `<base>` (e.g. `merged_into=develop` while `$BASE=master`). This is still a `candidate` row
   that `gantry:prune-worktrees` will offer to remove in Stage 7, so it must be shown here too — one
   line per row (or a count plus the branch names) rather than being dropped.
3. **Stale only** — `merged_into` is `-` and `days_idle >= 7`. Pre-existing; one line with a
   count.

Every `candidate` row lands in exactly one of the three buckets above — that is what keeps
Stage 7's handoff from ever offering to remove something this report never showed the operator.

Plus a one-line count of what was skipped and why (`locked`, `dirty`) — a dirty worktree that
looks prunable and silently is not is the report's worst failure. `main` and `current` are never
reported, matching `prune-worktrees` step 3.

Also report, as an FYI and **never** acted on, merged local branches:

```bash
git -C "$MAIN_ROOT" branch --merged "$BASE" --format='%(refname:short)'
```

excluding `$BASE` itself and any name still checked out in a worktree. Give the manual
`git branch -d <name>` line, exactly as `prune-worktrees`' Report does. This skill never deletes
a branch.

**Zero candidates** → say "nothing became prunable" in one line and go to the Report — do not
invoke `gantry:prune-worktrees`.

## Stage 7 — Hand off

Candidates > 0 → **invoke `gantry:prune-worktrees`** and let it own detection-again, the
`AskUserQuestion` confirm, the dirty re-check, and the removal. `gantry:sync` removes nothing itself
and deletes no branches, ever. `AskUserQuestion` is in this skill's `allowed-tools` **only** so the
invoked skill's confirmation prompt is not blocked by the caller's tool scope — `gantry:sync` never
calls it itself; Stage 1 and Stage 5's prohibitions are what keep it from asking anything of its
own.

Zero candidates → one line in the report, no invocation.

## Report

- The base and how it was resolved (argument / profile / detection, and which detection rule).
- What moved: `OLD_SHA..NEW_SHA` with the commit count, or "already current".
- What is now prunable (the three buckets from Stage 6, or the merge-classification-unavailable
  note if `$BASE` isn't `develop`/`master`/`main`), or "nothing became prunable".
- What was actually pruned (from Stage 7's handoff), or "no removals — zero candidates".
- Any warnings: **a failed fetch** — this can only be Stage 6's `detect_candidates.sh` fetch, since
  an unrecoverable Stage 2 fetch failure stops the whole run before this Report is ever reached —
  plus the base living in another worktree, or a dirty non-main worktree that `gantry:prune-worktrees`
  will skip.
