#!/usr/bin/env bash
#
# tally.sh <file> — print the number of lines in <file>.
#
# Exit codes: 0 = counted · 2 = usage, or no such file.

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/tally.sh
. "$here/../lib/tally.sh"

[ "$#" -eq 1 ] || {
  printf 'usage: tally.sh <file>\n' >&2
  exit 2
}

file="$1"
[ -f "$file" ] || {
  printf 'tally: no such file: %s\n' "$file" >&2
  exit 2
}

count_lines "$file"
