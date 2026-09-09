#!/usr/bin/env bash
#
# GitHub renders a pull request body in comment mode, where a single newline
# inside a paragraph becomes a `<br>`. check_pr_body.sh refuses a body written
# in the 100-column habit every other markdown file here follows.
#
# The cases below are the shapes that decided the checker's rules, and each one
# was confirmed against GitHub's own renderer (POST /markdown, mode=gfm) before
# it was written down: the structural ones produce no `<br>` and must pass, the
# continuation ones produce one and must fail. The tight-list case is the one
# a naive "two prose lines in a row" rule gets wrong.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

CHECK="$GANTRY_ROOT/scripts/check_pr_body.sh"

body() {  # body <name> <content>
  printf '%s\n' "$2" > "$CASE_TMP/$1.md"
  printf '%s' "$CASE_TMP/$1.md"
}

check() {  # check <file> -> sets OUT and RC
  OUT="$(bash "$CHECK" "$1" 2>&1)"; RC=$?
}

check "$(body flowing 'One paragraph on one long line, however long it runs.

And a second one, also on one line.')"
assert_rc 0 "$RC" "one line per paragraph passes"

check "$(body wrapped 'A paragraph that somebody wrapped
at a column, the way every .md file here is wrapped.')"
assert_rc 1 "$RC" "a wrapped paragraph fails"
assert_contains "$OUT" "line 2" "and names the continuation line"

check "$(body tight '- one item
- two items
- three items')"
assert_rc 0 "$RC" "a tight list is not a wrapped paragraph"

check "$(body itemwrap '- an item whose text was wrapped
  onto a second line')"
assert_rc 1 "$RC" "a wrapped list item fails"

check "$(body table '| a | b |
|---|---|
| 1 | 2 |')"
assert_rc 0 "$RC" "a table is line-structured on purpose"

check "$(body fenced 'Prose here.

```bash
one
two
```')"
assert_rc 0 "$RC" "lines inside a fence are left alone"

check "$(body heads '## One

## Two')"
assert_rc 0 "$RC" "headings pass"

check "$(body quotedlist '> - a quoted item
> - a second quoted item')"
assert_rc 0 "$RC" "a quoted tight list is judged as the list it is"

check "$(body quotedwrap '> a quoted paragraph that was
> wrapped at a column')"
assert_rc 1 "$RC" "a wrapped quoted paragraph fails"

check "$(body explicit 'a line asking for a break  
and the line after it')"
assert_rc 0 "$RC" "two trailing spaces asked for the break"

OUT="$(bash "$CHECK" "$CASE_TMP/nope.md" 2>&1)"; RC=$?
assert_rc 2 "$RC" "a missing file is a usage error"

OUT="$(bash "$CHECK" 2>&1)"; RC=$?
assert_rc 2 "$RC" "no argument is a usage error"

finish
