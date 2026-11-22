#!/usr/bin/env bash
#
# config.sh — read a flat key=value configuration file. Sourced by the scripts
# in bin/; it defines functions and runs nothing.

set -uo pipefail

# config_has_key <file> <key> — exit 0 when <key> is set in <file>, 1 when it
# is not. Prints nothing: the status is the answer.
config_has_key() {
  local file="$1" key="$2"
  grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$file"
}

# config_value <file> <key> — print the value of <key>, or nothing.
config_value() {
  local file="$1" key="$2"
  sed -n "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//p" "$file" | head -1
}
