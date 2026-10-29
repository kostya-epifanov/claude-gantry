#!/usr/bin/env bash
#
# upload.sh <dir> — copy the recent backups in <dir> to the remote store.

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/backups.sh
. "$here/../lib/backups.sh"

dir="${1:?usage: upload.sh <dir>}"
remote="${REMOTE:-backup@example.invalid:/srv/backups}"

# The upload cutoff is its own number and is computed here rather than in the
# library, because it answers a different question from pruning's cutoff.
cutoff_days="${UPLOAD_CUTOFF_DAYS:-7}"

while IFS= read -r f; do
  [ -n "$f" ] || continue
  printf 'would upload %s -> %s\n' "$f" "$remote"
done < <(find "$dir" -maxdepth 1 -name 'backup-*.tar.gz' -type f -mtime -"$cutoff_days")
