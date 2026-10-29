#!/usr/bin/env bash
#
# backups.sh — find backup archives in a directory. Sourced by the scripts in
# bin/; it defines functions and runs nothing.

set -uo pipefail

# backup_files <dir> — every backup in <dir>, newest name first.
backup_files() {
  local dir="$1"
  find "$dir" -maxdepth 1 -name 'backup-*.tar.gz' -type f | sort -r
}

# older_than <dir> <days> — the backups in <dir> last modified more than
# <days> days ago.
older_than() {
  local dir="$1" days="$2"
  find "$dir" -maxdepth 1 -name 'backup-*.tar.gz' -type f -mtime +"$days"
}
