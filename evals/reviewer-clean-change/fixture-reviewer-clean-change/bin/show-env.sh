#!/usr/bin/env bash
#
# show-env.sh — print the environment variables this tool reads.

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/table.sh
. "$here/../lib/table.sh"

heading 'Environment'
for name in EDITOR PAGER TMPDIR; do
  row "$name" "${!name:-(unset)}"
done
