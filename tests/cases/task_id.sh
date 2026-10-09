#!/usr/bin/env bash
#
# lib/task_id.sh — the tracker id a run carries, and the explicit branch. The
# drivers name the branch and worktree `<type>/<ID>-<slug>` when there is an
# id and exactly as before when there is not, so the assertions that matter
# most are the ones where nothing must be found: ordinary hyphenated words,
# a flag's value, a date-slug id in task.md.
#
# The argument string is written to a file with printf, never passed through
# a shell word, which is the convention the script enforces on its callers.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

TASK_ID="$GANTRY_ROOT/lib/task_id.sh"

ARGS="$CASE_TMP/args.txt"
TASK="$CASE_TMP/task.md"

# parse <argument string> [extra args...] — sets R_OUT and R_RC.
parse() {
  local text="$1"; shift
  printf '%s' "$text" >"$ARGS"
  R_OUT="$(bash "$TASK_ID" --args-file "$ARGS" "$@" 2>&1)"
  R_RC=$?
  return 0
}

# parse_file <task.md contents> — the task-file source on its own.
parse_file() {
  printf '%s\n' "$1" >"$TASK"
  R_OUT="$(bash "$TASK_ID" --task-file "$TASK" 2>&1)"
  R_RC=$?
  return 0
}

line() {  # line <KEY> — the value of that output line, or <absent> if it is not there
  if printf '%s\n' "$R_OUT" | grep -q "^$1:"; then
    printf '%s\n' "$R_OUT" | sed -n "s/^$1://p" | head -n 1
  else
    printf '<absent>'
  fi
}

assert_eq() {  # assert_eq <expected> <actual> <label>
  if [ "$1" = "$2" ]; then _pass "$3"; else _fail "$3 — expected '$1', got '$2'"; fi
}

# --- the three forms from the acceptance criteria ---------------------------------

parse 'BASE-71 integrate should update docs'
assert_rc 0 "$R_RC" "an id at the start of the task parses"
assert_eq 'BASE-71' "$(line ID)" "and is reported as the id"
assert_eq 'text' "$(line SOURCE)" "from the text"
assert_eq '-' "$(line BRANCH)" "with no explicit branch"
assert_eq 'integrate should update docs' "$(line TEXT)" "and the id removed from the text"

parse 'integrate should update docs'
assert_rc 0 "$R_RC" "a task with no id parses"
assert_eq '-' "$(line ID)" "and reports no id"
assert_eq '-' "$(line SOURCE)" "and no source"
assert_eq 'integrate should update docs' "$(line TEXT)" "and the text untouched"

parse '--branch feat/custom BASE-71 integrate should update docs'
assert_eq 'feat/custom' "$(line BRANCH)" "an explicit --branch is reported verbatim"
assert_eq 'BASE-71' "$(line ID)" "and the id is still found behind it"
assert_eq 'integrate should update docs' "$(line TEXT)" "and both are stripped from the text"

# --- precedence -----------------------------------------------------------------------

parse '--task GH-9 BASE-71 integrate should update docs'
assert_eq 'GH-9' "$(line ID)" "--task beats an id in the text"
assert_eq 'flag' "$(line SOURCE)" "and says so"
assert_eq 'integrate should update docs' "$(line TEXT)" "with both ids removed from the text"

parse 'integrate should update docs --task GH-9'
assert_eq '-' "$(line ID)" "--task after the task text is text, not a flag"
assert_eq 'integrate should update docs --task GH-9' "$(line TEXT)" "and stays in the text for the driver to see"

parse 'BASE-71 fix https://github.com/acme/site/issues/9'
assert_eq 'BASE-71' "$(line ID)" "an id in the text beats a URL"
assert_eq 'text' "$(line SOURCE)" "and says so"

printf 'id: BASE-5\n' >"$TASK"
parse 'fix https://github.com/acme/site/issues/9' --task-file "$TASK"
assert_eq 'GH-9' "$(line ID)" "a URL beats task.md"
assert_eq 'url' "$(line SOURCE)" "and says so"

printf 'id: BASE-5\n' >"$TASK"
parse 'BASE-71 fix it' --task-file "$TASK"
assert_eq 'BASE-71' "$(line ID)" "the argument string beats task.md"
parse 'fix it' --task-file "$TASK"
assert_eq 'BASE-5' "$(line ID)" "and task.md is the last resort"
assert_eq 'task.md' "$(line SOURCE)" "and says so"

# --- the drivers' own flags ------------------------------------------------------------

parse '--no-pr BASE-71 fix the docs'
assert_eq 'BASE-71' "$(line ID)" "a leading --no-pr does not hide the id"
assert_eq '--no-pr fix the docs' "$(line TEXT)" "and the flag is left for the driver"

parse '--base develop BASE-71 fix the docs'
assert_eq 'BASE-71' "$(line ID)" "a flag's value is not taken as the first token"
assert_eq '--base develop fix the docs' "$(line TEXT)" "and the flag and its value stay"

parse '--here --lead lead-1 BASE-71 fix the docs'
assert_eq 'BASE-71' "$(line ID)" "several flags are skipped"
assert_eq '--here --lead lead-1 fix the docs' "$(line TEXT)" "and all of them stay"

parse 'BASE-71: fix the docs'
assert_eq 'BASE-71' "$(line ID)" "a trailing colon on the id is tolerated"
assert_eq 'fix the docs' "$(line TEXT)" "and removed with it"

parse '--task BASE-71: fix the docs'
assert_eq 'BASE-71' "$(line ID)" "and on the flag form too"

parse 'BASE-80 explain why --branch wins over --here'
assert_eq '-' "$(line BRANCH)" "--branch inside the task text is a word, not a flag"
assert_eq 'explain why --branch wins over --here' "$(line TEXT)" "and every word of the text survives"

parse 'make journal_append --task optional'
assert_rc 0 "$R_RC" "--task inside the task text is not a usage error"
assert_eq '-' "$(line ID)" "and names no id"
assert_eq 'make journal_append --task optional' "$(line TEXT)" "and the text is untouched"

# --- URLs, in the shapes they are actually copied ---------------------------------

parse 'fix https://github.com/acme/site/issues/71#issuecomment-1 please'
assert_eq 'GH-71' "$(line ID)" "a GitHub issue URL gives GH-<n>"
assert_eq 'url' "$(line SOURCE)" "from the url"

parse 'fix https://linear.app/acme/issue/BASE-78/some-title-slug'
assert_eq 'BASE-78' "$(line ID)" "a Linear URL with a title slug gives the key"
assert_eq 'url' "$(line SOURCE)" "from the url"

parse 'fix https://acme.atlassian.net/browse/PROJ-7?focusedCommentId=1'
assert_eq 'PROJ-7' "$(line ID)" "a Jira browse URL with a query gives the key"
assert_eq 'url' "$(line SOURCE)" "from the url"

parse 'fix https://github.com/o/r/issues/71abc'
assert_eq '-' "$(line ID)" "a GitHub issue number with a tail is not an issue"

parse 'fix https://notgithub.com/o/r/issues/5'
assert_eq '-' "$(line ID)" "a host that merely ends in github.com is not GitHub"

parse 'fix https://linear.app/w/issue/ABCDEFGHIJKLMNOPQRSTUVWXYZABCDEFGH-1'
assert_eq '-' "$(line ID)" "a URL id over 32 characters is capped like every other source"

parse 'fix https://linear.app/acme/issue/BASE-78/slug'
assert_eq 'fix https://linear.app/acme/issue/BASE-78/slug' "$(line TEXT)" "a URL stays in the text"

# --- what must not be an id ---------------------------------------------------------------

parse 'utf-8 decoding bug'
assert_eq '-' "$(line ID)" "utf-8 is a word, not an id"
assert_eq 'utf-8 decoding bug' "$(line TEXT)" "and the text is untouched"

parse 'covid-19 dashboard'
assert_eq '-' "$(line ID)" "covid-19 is a word, not an id"

parse 'proj-3 thing'
assert_eq '-' "$(line ID)" "a lowercase key is not an id"

parse 'fix BASE-71 later'
assert_eq '-' "$(line ID)" "an id that is not the first token is not taken"

parse 'A-1-2 thing'
assert_eq '-' "$(line ID)" "a second hyphen is not an id"

printf 'x' >"$CASE_TMP/glob.md"
( cd "$CASE_TMP" && printf '%s' 'BASE-71 fix the *.md files' >"$ARGS" \
    && bash "$TASK_ID" --args-file "$ARGS" ) >"$CASE_TMP/glob.out" 2>&1
R_OUT="$(cat "$CASE_TMP/glob.out")"
assert_eq 'fix the *.md files' "$(line TEXT)" "a glob in the text is not expanded, even where it would match"

printf 'BASE-71 fix the docs\r\n' >"$ARGS"
R_OUT="$(bash "$TASK_ID" --args-file "$ARGS" 2>&1)"
assert_eq 'BASE-71' "$(line ID)" "a CRLF args file still yields the id"
assert_eq 'fix the docs' "$(line TEXT)" "and no carriage return in the text"

# --- the task file ----------------------------------------------------------------------

parse_file $'---\nid: BASE-71   # the tracker id\ntitle: x\n---'
assert_rc 0 "$R_RC" "a task file on its own parses"
assert_eq 'BASE-71' "$(line ID)" "a trailing comment on id: is stripped"
assert_eq 'task.md' "$(line SOURCE)" "and the source is task.md"
assert_eq '' "$(line TEXT)" "and the TEXT line is present and empty"

parse_file $'---\nid: 2026-07-18-contact-form\n---'
assert_eq '-' "$(line ID)" "a date-slug id is not a tracker id"

parse_file $'---\ntitle: no id line\n---'
assert_eq '-' "$(line ID)" "a task file with no id: line gives no id"

# --- refusals -------------------------------------------------------------------------------

parse '--task not_an_id fix it'
assert_rc 2 "$R_RC" "--task with a value that is not an id is a usage error"
assert_eq '<absent>' "$(line ID)" "and nothing is printed on stdout"

parse '--task'
assert_rc 2 "$R_RC" "--task with no value is a usage error"

parse '--branch'
assert_rc 2 "$R_RC" "--branch with no value is a usage error"

parse '--branch --no-pr fix it'
assert_rc 2 "$R_RC" "--branch followed by a flag has no value"

parse '--branch a --branch b fix it'
assert_rc 2 "$R_RC" "--branch given twice is a usage error"

parse '--task GH-1 --task GH-2 fix it'
assert_rc 2 "$R_RC" "--task given twice is a usage error"

R_OUT="$(bash "$TASK_ID" 2>&1)"; R_RC=$?
assert_rc 2 "$R_RC" "no input at all is a usage error"

R_OUT="$(bash "$TASK_ID" --args-file "$CASE_TMP/missing.txt" 2>&1)"; R_RC=$?
assert_rc 2 "$R_RC" "a missing args file is a usage error"

finish
