# Plan — a keep-floor for prune.sh

Contract: the task file beside this one. `bin/prune.sh` gains a floor; `lib/backups.sh` gains one
helper.

## Steps

### 1. A helper that returns the prunable set

Add `prunable <dir> <days> <keep>` to `lib/backups.sh`. It lists the directory newest-first with
the existing `backup_files`, drops the first `<keep>` entries, and prints what is left of them that
`older_than` also names. The intersection is what may be removed, so the floor holds whatever the
ages are.

### 2. Teach prune.sh the floor

`prune.sh <dir> [days] [keep]` — `keep` defaults to 3. Replace the `older_than` call in the loop
with `prunable`, and leave the loop body alone.

### 3. Fold the cutoff computation into the library

`bin/upload.sh` computes its own cutoff inline with a bare `find`, duplicating the date arithmetic
that `older_than` already owns. Add `newer_than <dir> <days>` beside it and change `upload.sh` to
call that, so both scripts get their file lists from the same place and a change to the convention
lands in one file.

### 4. Empty directory

`find` over a directory with no matches prints nothing, the loop runs zero times, the script exits
0. Already true; no code.

## Test strategy

A fixture directory with four archives whose modification times are set with `touch -t`, run at a
floor of 2 and of 3, asserting which files survive. Plus the empty-directory case.

## Known weak points

- `touch -t` in the fixture pins the test to a filesystem with reliable modification times.
