# Handover — feat/ship-discloses-what-was-not-proven

Deferred from *Make the draft PR body disclose what the run did not prove*. The change itself is
complete and the gate is green; this is the one finding review turned up that the change did not
absorb.

## `scripts/verify.sh`'s inline fixture suite passes for the wrong reason when `mktemp` fails

**What it is.** In `scripts/verify.sh`, the *"detect_stage.sh reads Open questions correctly"*
section builds its fixtures with an unguarded `fixdir="$(mktemp -d)"`. When `mktemp` cannot create
a directory — which happens on this machine under the Bash sandbox, where it fails with
*Operation not permitted* — `fixdir` becomes the empty string and is never checked. Everything
downstream then misbehaves in a specific and misleading way:

- `printf ... > "$fixdir/task.md"` writes to `/task.md`, which fails with a permission error per
  fixture rather than aborting the section;
- `forks_is` runs `(cd "$fixdir" && bash "$LIB")`, and `cd ""` **succeeds** in bash as a no-op — so
  the detector runs against **the real repository**, reading the worktree's own `task.md` instead
  of the fixture that was never written.

The result is not a clean failure. Roughly twenty assertions fail for a reason unrelated to any
change, and — the part that matters — every assertion whose expected value happens to match the
worktree's real `task.md` **passes for the wrong reason**. With this branch's `task.md` reporting
`FORKS:none`, all six `forks_is none` cases pass while testing nothing at all.

`tests/lib.sh` is not affected: it uses `mktemp -d "${TMPDIR:-/tmp}/gantry-test.XXXXXX"`, which
succeeds under the sandbox, and it resolves the result with `pwd -P`.

**Why it was deferred.** It is a pre-existing bug in code this change does not touch —
`scripts/verify.sh`'s fixture block predates this branch, and this task's *Out of scope* is the
disclosure work in ship, the detector and the journal. Fixing a test harness in the same diff that
adds a detector line would widen a focused change into one covering two unrelated subsystems. It is
also not urgent in CI, where `mktemp` is unrestricted and the section behaves correctly.

**What was already established.** Confirmed by direct observation on this branch, not inferred:
`bash scripts/verify.sh` under the sandbox reports `verify: FAIL` with
`mktemp: mkdtemp failed on ...: Operation not permitted` followed by
`error: could not lock config file .../.git/config` (the fixture's `git init` running against the
real repo) and `scripts/verify.sh: line NNN: /task.md: Operation not permitted` per fixture. The
same command run unsandboxed reports `verify: PASS`. The gate results recorded for this task are
all from unsandboxed runs for that reason. `/code-review` independently reached the same diagnosis
from reading the code.

Not established: whether any CI runner has ever hit this. Nothing suggests it has.

**Next action.** In `scripts/verify.sh`, guard the fixture directory the way the section's own
`bad "could not create the fixture repo"` branch already intends to:

```bash
fixdir="$(mktemp -d)" || { bad "could not create a fixture directory"; fixdir=""; }
[ -n "$fixdir" ] && [ -d "$fixdir" ] || { bad "fixture directory unavailable — section skipped"; }
```

and skip the section rather than run it against an empty path. The honest check on the fix is that
`TMPDIR=/nonexistent bash scripts/verify.sh` reports the section as skipped-and-failed rather than
printing `ok` lines. The same guard belongs on the `cd` inside `forks_is`, since `cd ""` silently
succeeding is what turns a broken fixture into a false green.
