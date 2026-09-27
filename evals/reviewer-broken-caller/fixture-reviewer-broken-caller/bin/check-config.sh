#!/usr/bin/env bash
#
# check-config.sh <file> <key>... — exit non-zero if any key is missing.

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/config.sh
. "$here/../lib/config.sh"

file="${1:?usage: check-config.sh <file> <key>...}"
shift

missing=0
for key in "$@"; do
  if config_has_key "$file" "$key"; then
    printf '%s: present\n' "$key"
  else
    printf '%s: missing\n' "$key"
    missing=$((missing + 1))
  fi
done

[ "$missing" -eq 0 ] || exit 1
