#!/usr/bin/env bash
#
# lib/session_paths.sh is the one definition of where gantry writes outside the
# repo. skills/preserve/scripts/doc_path.sh carried that convention inline until
# lib/archive_artifacts.sh needed the same answer; it now sources the lib.
#
# THE ERROR PATH IS THE POINT OF THE SECOND HALF. doc_path.sh runs under
# `set -uo pipefail` deliberately WITHOUT `-e`, because every labeled line it
# prints must appear even when a step fails — a caller parses them. A sourced
# file that opened with `set -euo pipefail` would turn `-e` on inside it, and
# its `mkdir -p "$DIR"` would then exit before a single line was printed. That
# failure is invisible on the happy path, so it is asserted here with $HOME
# pointed at a directory nothing can write into.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

PATHS_LIB="$GANTRY_ROOT/lib/session_paths.sh"
DOC_PATH="$GANTRY_ROOT/skills/preserve/scripts/doc_path.sh"

# --- the functions -----------------------------------------------------------

# shellcheck source=lib/session_paths.sh
. "$PATHS_LIB"

assert_eq() {  # assert_eq <got> <want> <label>
  if [ "$1" = "$2" ]; then _pass "$3"; else _fail "$3 — got '$1', want '$2'"; fi
}

assert_eq "$(repo_slug /home/x/LAB/repo)" "-home-x-LAB-repo" \
  "repo_slug replaces every slash, leading one included"
assert_eq "$(slugify 'Feat/Some Branch')" "feat-some-branch" \
  "slugify lowercases and collapses non-alphanumerics"
assert_eq "$(slugify '-')" "" \
  "slugify of a lone dash is EMPTY — the detached-worktree case callers must handle"
assert_eq "$(HOME=/h sessions_dir /home/x/LAB/repo)" "/h/.claude/sessions/-home-x-LAB-repo" \
  "sessions_dir is \$HOME/.claude/sessions/<repo-slug>"

# Sourcing it must not have turned on `-e` or `-u` in this shell, which is the
# whole constraint on the file.
case "$-" in
  *e*) _fail "sourcing session_paths.sh turned on errexit in its caller" ;;
  *)   _pass "sourcing session_paths.sh sets no shell options in its caller" ;;
esac

# --- doc_path.sh still prints its contract ----------------------------------

repo="$(mkrepo preserve-repo)"

run_doc_path() {  # run_doc_path <home> [label-arg] — sets DOC_OUT
  local home="$1"; shift
  DOC_OUT="$(cd "$repo" && HOME="$home" bash "$DOC_PATH" "$@" 2>&1)"
  return 0
}

good_home="$CASE_TMP/home-ok"
mkdir -p "$good_home"
run_doc_path "$good_home" my-label
for k in DOC= REPO= BRANCH= SLUG= EXISTS=; do
  assert_contains "$DOC_OUT" "$k" "doc_path prints $k on the happy path"
done
assert_contains "$DOC_OUT" "== RECENT ==" "doc_path prints the RECENT block"
assert_contains "$DOC_OUT" "SLUG=my-label" "the label argument becomes the slug"
assert_contains "$DOC_OUT" "$good_home/.claude/sessions/" \
  "the document lands under \$HOME/.claude/sessions/"
assert_path_present "$good_home/.claude/sessions" "the sessions directory was created"

# $HOME unwritable: `mkdir -p` fails, and every line must still print.
bad_home="$CASE_TMP/home-ro"
mkdir -p "$bad_home"
chmod 500 "$bad_home"
run_doc_path "$bad_home"
for k in DOC= REPO= BRANCH= SLUG= EXISTS=; do
  assert_contains "$DOC_OUT" "$k" "doc_path still prints $k when \$HOME cannot be written"
done
assert_contains "$DOC_OUT" "== RECENT ==" "and still prints the RECENT block"
chmod 700 "$bad_home"

# --- but a MISSING lib is fatal, not another printed line -------------------
#
# The one exception to "print the lines anyway". Without `-e`, bash carries on
# past a failed `.`, leaving `slugify` and `sessions_dir` undefined and `DIR`
# empty — and doc_path.sh then printed `DOC=/<date>-session.md`, the filesystem
# ROOT, and exited 0. A caller parsing that would have gantry:preserve write
# outside any sessions directory. doc_path.sh was self-contained before it
# sourced the lib, so this is the failure the refactor had to not introduce.
fake="$CASE_TMP/plugin-without-lib/skills/preserve/scripts"
mkdir -p "$fake"
cp "$DOC_PATH" "$fake/doc_path.sh"
DOC_OUT="$(cd "$repo" && HOME="$good_home" bash "$fake/doc_path.sh" lbl 2>&1)"
DOC_RC=$?
assert_rc 2 "$DOC_RC" "doc_path.sh with lib/session_paths.sh missing is exit 2"
assert_not_contains "$DOC_OUT" "DOC=/20" \
  "and prints no DOC= line pointing at the filesystem root"

finish
