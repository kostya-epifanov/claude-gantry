#!/usr/bin/env bash
# check_pr_body.sh — refuse a pull request body that was hard-wrapped.
# Run with: bash check_pr_body.sh <file>   (or `-` for stdin)
#
# WHY THIS EXISTS. GitHub renders a pull request body in *comment* mode, where a
# single newline inside a paragraph becomes a `<br>`. Every other markdown file
# in this repository is hard-wrapped at 100 columns, and a body composed in that
# habit renders as a ragged column broken mid-sentence rather than as prose.
# Nine of this repository's first sixteen pull requests shipped that way, 315
# spurious breaks between them, before anybody noticed — which is the argument
# for a check rather than a sentence in a SKILL.md. Verified against GitHub's
# own renderer: POST /markdown with mode=gfm turns "a\nb" into "a<br>b", while
# mode=markdown does not.
#
# WHAT COUNTS AS A BREAK. Two consecutive non-blank lines where the second is a
# continuation rather than a new block. Structure whose line layout is load-
# bearing is exempt, because none of it produces a `<br>`: fenced code, table
# rows, headings, thematic breaks, raw HTML, and one list item following
# another. A line ending in two spaces or a backslash asked for the break and is
# left alone. Blockquote markers are stripped before any of this is decided, so
# a quoted list is judged as the list it is.
#
# Exit codes: 0 = no spurious break · 1 = at least one, listed on stdout
# · 2 = usage.
set -uo pipefail

[ "$#" -eq 1 ] || { printf 'usage: check_pr_body.sh <file>|-\n' >&2; exit 2; }

if [ "$1" = "-" ]; then
  body="$(cat)"
else
  [ -f "$1" ] || { printf 'check_pr_body: no such file: %s\n' "$1" >&2; exit 2; }
  body="$(cat "$1")"
fi

printf '%s\n' "$body" | awk '
  function classify(s,   t) {
    # Strip blockquote markers first: a quoted list is a list.
    t = s
    while (t ~ /^[ \t]*>/) { sub(/^[ \t]*>[ \t]?/, "", t) }
    if (t ~ /^[ \t]*$/)                      return "blank"
    if (t ~ /^ {0,3}(```|~~~)/)              return "fence"
    if (t ~ /^ {0,3}#{1,6}[ \t]/)            return "structure"   # heading
    if (t ~ /^[ \t]*\|/)                     return "structure"   # table row
    if (t ~ /^ {0,3}([-*_])([ \t]*\1){2,}[ \t]*$/) return "structure"  # rule
    if (t ~ /^ {0,3}</)                      return "structure"   # raw HTML
    if (t ~ /^[ \t]*([-*+]|[0-9]+[.)])[ \t]+/) return "item"
    return "prose"
  }
  function asked_for_break(s) { return (s ~ /(  |\\)$/) }

  BEGIN { infence = 0; prev = "blank"; bad = 0 }
  {
    kind = classify($0)
    if (infence) { if (kind == "fence") infence = 0; prev = "blank"; next }
    if (kind == "fence") { infence = 1; prev = "blank"; next }

    # A continuation of the previous line is what GitHub turns into a <br>.
    if ((prev == "prose" || prev == "item") && (kind == "prose") \
        && !asked_for_break(prevline)) {
      bad++
      printf "  line %d: %s\n", NR, substr($0, 1, 72)
    }
    prev = kind
    prevline = $0
  }
  END {
    if (bad) {
      printf "\ncheck_pr_body: %d hard-wrapped line(s).\n", bad
      print  "GitHub renders a PR body in comment mode: a single newline inside a"
      print  "paragraph becomes a <br>. Put each paragraph on one line and let it wrap."
      exit 1
    }
  }
'
