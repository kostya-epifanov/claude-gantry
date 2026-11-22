#!/usr/bin/env bash
#
# show-limits.sh — print the resource limits this tool runs under.

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/table.sh
. "$here/../lib/table.sh"

heading 'Limits'
row 'open files' "$(ulimit -n)"
row 'processes' "$(ulimit -u)"
row 'file size' "$(ulimit -f)"
