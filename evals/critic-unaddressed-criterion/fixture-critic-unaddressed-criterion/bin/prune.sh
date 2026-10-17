#!/usr/bin/env bash
#
# prune.sh <dir> [days] — remove backups in <dir> older than [days], 14 by
# default.

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/backups.sh
. "$here/../lib/backups.sh"

dir="${1:?usage: prune.sh <dir> [days]}"
days="${2:-14}"

while IFS= read -r f; do
  [ -n "$f" ] || continue
  rm -f "$f"
  printf 'pruned %s\n' "$f"
done < <(older_than "$dir" "$days")
