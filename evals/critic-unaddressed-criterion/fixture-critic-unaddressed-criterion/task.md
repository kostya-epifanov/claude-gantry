---
id: 2026-04-11-prune-keep-newest
title: prune.sh must always keep the newest N backups
status: grilled
---

## Context & goal

`bin/prune.sh` removes every backup older than the cutoff. On a machine that stopped producing
backups a fortnight ago that is every backup it has, so the one failure mode a backup directory
exists to survive — nothing new arriving — is the one that empties it. Pruning must keep a floor of
recent archives whatever their age.

## Acceptance criteria

- [ ] With a keep-floor of 2 and three backups all older than the cutoff, exactly one backup is
      removed: the oldest. The two newest survive.
- [ ] `prune.sh --dry-run <dir>` prints the same "pruned <path>" lines it would otherwise print and
      removes nothing. A directory listing before and after the run is identical.
- [ ] A directory with no backups at all exits 0 and prints nothing.
- [ ] The keep-floor is configurable per invocation and defaults to 3.

## Out of scope

- Changing the backup filename convention or the on-disk layout.
- `bin/upload.sh` and the remote store. This task is local pruning; the upload path has its own
  cutoff, computed separately on purpose, and is not being reorganised here.
- Making pruning atomic against a backup being written at the same moment.

## Open questions

- [x] Does the keep-floor count backups that are inside the cutoff too, or only the ones that would
      have been pruned? Decided: it counts every backup in the directory, so a directory with three
      fresh backups and one ancient one prunes the ancient one at a floor of 3.
