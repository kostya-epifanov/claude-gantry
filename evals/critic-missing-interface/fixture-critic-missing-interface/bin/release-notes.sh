#!/usr/bin/env bash
#
# release-notes.sh [version] — print the changelog section for a version,
# defaulting to the newest one in the file.

set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/changelog.sh
. "$here/../lib/changelog.sh"

CHANGELOG="${CHANGELOG:-$here/../CHANGELOG.md}"

[ -f "$CHANGELOG" ] || {
  printf 'release-notes: no changelog at %s\n' "$CHANGELOG" >&2
  exit 2
}

version="${1:-}"
if [ -z "$version" ]; then
  version="$(latest_version "$CHANGELOG")"
fi

section_for "$CHANGELOG" "$version"
