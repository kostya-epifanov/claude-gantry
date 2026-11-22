#!/usr/bin/env bash
#
# table.sh — the two-column layout the report scripts share. Sourced by the
# scripts in bin/; it defines functions and runs nothing.

set -uo pipefail

TABLE_LABEL_WIDTH=24

# heading <text> — print a section heading and the rule under it.
heading() {
  local text="$1"
  printf '\n%s\n' "$text"
  printf '%s\n' "${text//?/-}"
}

# row <label> <value> — print one row of the two-column table. The width lived
# as a literal in each caller's printf, which is why TABLE_LABEL_WIDTH could be
# changed here without either of them noticing.
row() {
  local label="$1" value="$2"
  printf '%-*s %s\n' "$TABLE_LABEL_WIDTH" "$label" "$value"
}
