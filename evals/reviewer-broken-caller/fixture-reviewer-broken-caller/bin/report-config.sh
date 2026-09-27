#!/usr/bin/env bash
#
# report-config.sh <file> <key>... — print a table of keys and their values,
# leaving the value column blank for a key that is not set.

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/config.sh
. "$here/../lib/config.sh"

file="${1:?usage: report-config.sh <file> <key>...}"
shift

for key in "$@"; do
  present="$(config_has_key "$file" "$key")"
  if [ "$present" = "yes" ]; then
    printf '%-24s %s\n' "$key" "$(config_value "$file" "$key")"
  else
    printf '%-24s %s\n' "$key" "(unset)"
  fi
done
