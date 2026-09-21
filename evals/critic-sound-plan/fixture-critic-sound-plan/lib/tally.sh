#!/usr/bin/env bash
#
# tally.sh — count things in a file. Sourced by bin/tally.sh; it defines
# functions and runs nothing.

set -uo pipefail

# count_lines <file> — print the number of lines in <file>.
count_lines() {
  local file="$1"
  awk 'END { print NR }' "$file"
}

# count_words <file> — print the number of whitespace-separated words in
# <file>.
count_words() {
  local file="$1"
  awk '{ n += NF } END { print n + 0 }' "$file"
}
