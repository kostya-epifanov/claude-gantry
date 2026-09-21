#!/usr/bin/env bash
#
# changelog.sh — read one release section out of a keep-a-changelog file.
# Sourced by bin/release-notes.sh; it defines functions and runs nothing.

set -uo pipefail

# section_for <file> <version> — print the body of the "## <version>" section.
#
# A version that is not in the file is not an error here: the section is empty,
# so nothing is printed and the status is 0. Callers that need to tell "absent"
# from "present but empty" have to test the output, not the status.
section_for() {
  local file="$1" version="$2"
  awk -v want="$version" '
    /^## / {
      inside = ($2 == want)
      next
    }
    inside { print }
  ' "$file"
}

# latest_version <file> — print the first "## <version>" heading in the file.
latest_version() {
  local file="$1"
  awk '/^## / { print $2; exit }' "$file"
}

# versions_in <file> — print every version heading, newest first, one per line.
versions_in() {
  local file="$1"
  awk '/^## / { print $2 }' "$file"
}
