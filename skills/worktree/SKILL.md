---
name: worktree
description: Create a git worktree under .claude/worktrees/ from an up-to-date parent branch and enter it. Use when the user types "/gantry:worktree" with a branch name, or asks to start work on a new branch in a worktree.
argument-hint: [branch]
---

# gantry:worktree

Create a worktree at `.claude/worktrees/<arg>` on a new branch `<arg>`, branched from a freshly
fetched parent, and switch the session into it.

`/gantry:worktree feat/ui_kit` → branch `feat/ui_kit`, worktree at `<main-repo>/.claude/worktrees/feat/ui_kit`.

Worktrees are **always** created in the main repo, never nested inside another worktree — this
holds even when the skill is invoked from within a worktree.

## Steps

### 1. Parse the argument

`$ARGUMENTS` is the branch name, used verbatim as both the branch and the path under
`.claude/worktrees/`. Validate: each `/`-separated segment must match `[A-Za-z0-9._-]+`, 64 chars
max overall (an `EnterWorktree` constraint). If no argument was given, ask for one.

Below, `$ARG` is that value.

### 2. Resolve the main repo root

```bash
MAIN_ROOT="$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"
```

`--git-common-dir` resolves to the *main* repo's `.git` even from inside a worktree, which is what
keeps worktrees out of worktrees. Abort if not in a git repo.

### 3. Determine the base branch

- `develop`, if `refs/heads/develop` or `refs/remotes/origin/develop` exists.
- Otherwise the default branch: `git symbolic-ref refs/remotes/origin/HEAD` → `refs/remotes/origin/<base>`.
- If origin/HEAD is unset, fall back to whichever of `master` / `main` exists.

### 4. Confirm the parent

Compare `git rev-parse --abbrev-ref HEAD` against the base branch.

- **Equal** → parent is the base. Proceed without asking.
- **Different** → use **AskUserQuestion**: "You're on `<current>`, not `<base>`. Branch from
  `<current>`, or from `<base>`?" List `<base>` first as the recommended option. The answer is `$PARENT`.

### 5. Update the parent

```bash
git -C "$MAIN_ROOT" fetch origin "$PARENT"
```

**This fetch must actually succeed — check it, don't assume it.** Against an HTTPS remote it can
fail with `could not read Username for 'https://github.com': Device not configured` (the sandbox
blocks the credential helper's keychain access). If that happens, retry it per the usual rules for
a sandbox-caused failure. Everything downstream builds on `origin/$PARENT`, so a fetch that failed
quietly means a worktree branched off a stale base — the exact thing this skill exists to prevent.

If the fetch still fails (offline, auth expired), **say so prominently** — state that the base may
be stale and show the SHA being used — then continue. Never let a failed fetch pass silently.

Then refresh the local `$PARENT` ref:

- **No `origin/$PARENT`** (local-only branch) → warn, skip the update, base off the local ref.
- **`$PARENT` is checked out in a worktree** — find it in `git worktree list --porcelain` by
  `branch refs/heads/$PARENT`. If that checkout is clean, `git -C <wt> merge --ff-only origin/$PARENT`.
  If it's dirty or the fast-forward fails, warn and leave it alone.
- **Not checked out anywhere** → `git -C "$MAIN_ROOT" fetch origin "$PARENT:$PARENT"`
  (fast-forward-only by nature; warn on divergence).

**The new worktree is always based on `origin/$PARENT` when it exists**, so a local ref that
couldn't be fast-forwarded never yields a stale worktree. Updating the local branch is a
convenience to keep that checkout current — when it can't be done, warn and carry on.

Call the resulting start point `$BASE_REF` (`origin/$PARENT`, or local `$PARENT` if there's no remote).

### 6. Preflight collisions

First: if `.claude/worktrees/$ARG` already exists on disk but is **not** a registered worktree
(`git -C "$MAIN_ROOT" worktree list --porcelain`), abort and report — don't create anything over it.

Then check for an existing branch named `$ARG` **both locally and on the remote**:

```bash
git -C "$MAIN_ROOT" show-ref --verify --quiet "refs/heads/$ARG"    # local? exit 0 = exists
git -C "$MAIN_ROOT" ls-remote --heads origin "refs/heads/$ARG"     # remote? see below
```

The two checks are **not** read the same way. `show-ref --quiet` is exit-code-driven. `ls-remote`
exits **0 whether or not anything matched** — a remote branch exists only if its *output is
non-empty*; a non-zero exit means the check itself errored. Reading `ls-remote`'s exit code the way
you read `show-ref`'s reports "remote branch exists" every single time.

The remote-only case is the one that's easy to miss: nothing local collides, so without this check
the skill creates a fresh `$ARG` off `$BASE_REF` that shares **no ancestry** with `origin/$ARG` —
and the first push is either rejected or needs a force. Check the remote before creating anything.

`ls-remote` talks to the network, so it fails the same way as step 5's fetch under the sandbox
(`could not read Username`, or a `gh`/config `operation not permitted`). Retry it per the usual
rules. **A failed `ls-remote` is not the same as "no remote branch"** — if it can't be made to
succeed, say the check was inconclusive and that a same-named remote branch may exist.

This step only *decides*; nothing is created until step 8, so that step 7's exclude runs first:

- **Local branch + worktree** → skip creation entirely, enter that worktree at step 9, and say so.
- **Local branch, no worktree** → at step 8, `git worktree add` without `-b` or `--no-track`; warn
  that an existing branch is being reused (step 5's base does not apply — the branch keeps its own
  history).
- **Remote branch only** → *adopt it, don't create.* Fetch it now, and at step 8 add the worktree
  from the branch name with **no `-b` and no `--no-track`**:

  ```bash
  git -C "$MAIN_ROOT" fetch origin "$ARG"                                    # now
  git -C "$MAIN_ROOT" worktree add "$MAIN_ROOT/.claude/worktrees/$ARG" "$ARG"  # at step 8
  ```

  With no local `$ARG` but exactly one remote carrying it, `worktree add` creates the local branch
  from `origin/$ARG` and sets it as upstream — which is what you want here, unlike step 8's own
  command. Report the SHA it landed on, and state plainly that step 5's base was **not** used.
- **Neither** → the normal path; continue to step 8 as written.

### 7. Ensure `.claude/worktrees/` is excluded

`$GANTRY` is this skill's plugin root — resolve it from this file's own location rather than
hardcoding a path.

```bash
bash "$GANTRY/lib/ensure_excluded.sh" '**/.claude/worktrees/'
```

Not `check-ignore -q … || echo … >>`. That file is shared by every linked worktree — git maps
`info/` into the common git dir — so the read and the write of two lanes creating worktrees at the
same time interleave, and double-appended entries were observed. `ensure_excluded.sh` locks,
matches whole lines, and leaves exactly one copy however many lanes run it at once. It is also a
single command with no substitution, which a worktree-isolated session will run and the compound
form it replaces was refused.

### 8. Create

```bash
git -C "$MAIN_ROOT" worktree add --no-track -b "$ARG" \
  "$MAIN_ROOT/.claude/worktrees/$ARG" "$BASE_REF"
```

This is the **new-branch path only** — if step 6 found an existing branch, run the command it
chose here instead, and if it found an existing worktree, run nothing and go straight to step 9.

`--no-track` is required here: branching off a remote-tracking ref otherwise sets upstream to
`origin/$PARENT`, so `git status` and a bare `git push` on the new branch would compare against
the parent. (It is deliberately *absent* from step 6's adopt case, where tracking `origin/$ARG` is
correct.) Intermediate directories are created automatically.

Under the sandbox this can fail **partway**: `.git/config` is not writable, so git creates the
branch, then aborts with `could not lock config file` before the worktree exists. The leftover
branch is not a stub to clean up — re-run the command unsandboxed and it will check out the branch
that's already there. Verify with `git worktree list` rather than assuming the failure was total.

### 9. Enter

**EnterWorktree** with `path: "$MAIN_ROOT/.claude/worktrees/$ARG"`.

Always `path`, never `name`. `name` refuses to run from inside an existing worktree session and
resolves `.claude/worktrees/` against the wrong root; `path` is supported from within a worktree
so long as the target is under the same repo's `.claude/worktrees/`, and a worktree entered by
`path` is never auto-removed by `ExitWorktree`. If the call is rejected, report the path so the
user can open it manually.

### 10. Report

The branch, the parent and the SHA it resolved to, the worktree path, and any warnings from
step 5. If step 6 adopted an existing local or remote branch, lead with that — the user asked for
a branch off a fresh parent and did not get one, so the parent is irrelevant to what they now have.
