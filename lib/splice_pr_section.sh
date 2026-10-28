#!/usr/bin/env bash
# splice_pr_section.sh — replace ONE `## ` section of a pull request body and
# print the result, leaving every other byte alone.
# Run with: bash splice_pr_section.sh <body-file> <section-file> <heading>
#
# <heading> is the heading TEXT without the `## ` (e.g. "Deliberately not
# done"). <section-file> carries the replacement INCLUDING its own `## `
# heading line.
#
# WHY A SCRIPT. This is the one destructive act in ship's body refresh: it
# rewrites prose a human may have edited on GitHub after the pull request
# opened. A wholesale recompose would overwrite that; replacing one named
# section does not. Deciding where a section ends is exactly the kind of
# judgement lib/detect_stage.sh spells out in a header comment rather than
# trusting to a model reading prose, so it is spelled out here too.
#
# THE BOUNDARY RULES.
#   - The section STARTS at the first line that is exactly `## <heading>`
#     (trailing whitespace ignored), OUTSIDE a fenced block.
#   - It ENDS at the next line beginning `## ` outside a fence, or at end of
#     file. A `### ` subheading does not end it.
#   - MORE THAN ONE matching heading -> exit 1, print nothing. Ambiguity is not
#     resolved by picking one.
#   - Heading ABSENT -> the section is inserted before `## Not proven by this
#     run` if the body has one, else appended at the end. That anchor is
#     gantry's own body layout (skills/ship/SKILL.md fixes its spelling);
#     `gantry:ship` is this script's only caller.
#   - `\r` is stripped from the body before anything else. scripts/check_pr_body.sh
#     never strips it, and a "\r" paragraph separator classifies as prose, so
#     every following paragraph would trip its break test — after which ship's
#     standing instruction ("fix what it names and run it again") would have a
#     model reflow a body it was told to leave byte-identical. Whether GitHub
#     ever returns CRLF for a web-edited body is UNVERIFIED: every
#     gantry-authored body on this repository round-trips as LF. The mitigation
#     costs one line and removes the hazard either way, so it is unconditional
#     and the premise stays recorded as unconfirmed.
#
# stdout: the spliced body. Nothing is printed on any non-zero exit.
# Exit codes: 0 = spliced · 1 = the heading is ambiguous, nothing changed
# · 2 = usage.
set -uo pipefail

die() { printf 'splice_pr_section: %s\n' "$1" >&2; exit 2; }

[ "$#" -eq 3 ] || die "usage: splice_pr_section.sh <body-file> <section-file> <heading>"

BODY_FILE="$1"
SECTION_FILE="$2"
HEADING="$3"

[ -f "$BODY_FILE" ]    || die "no such body file: $BODY_FILE"
[ -f "$SECTION_FILE" ] || die "no such section file: $SECTION_FILE"
[ -n "$HEADING" ]      || die "the heading must not be empty"

WANT="## $HEADING"
ANCHOR='## Not proven by this run'

BODY="$(tr -d '\r' <"$BODY_FILE")" || die "could not read $BODY_FILE"

# Counted BEFORE anything is printed, because an ambiguous heading must leave
# stdout empty rather than half-spliced.
COUNT="$(printf '%s\n' "$BODY" | awk -v h="$WANT" '
  { l = $0; sub(/[ \t]+$/, "", l)
    if (l ~ /^ {0,3}(```|~~~)/) { infence = !infence; next }
    if (!infence && l == h) n++ }
  END { print n + 0 }
')"

if [ "$COUNT" -gt 1 ]; then
  printf 'splice_pr_section: the heading "%s" appears %s times in %s; refusing to guess which one\n' \
    "$WANT" "$COUNT" "$BODY_FILE" >&2
  exit 1
fi

if [ "$COUNT" -eq 1 ]; then
  # Replace in place. Fence state is tracked while skipping too, so a fenced
  # `## ` inside the old section cannot end it early.
  printf '%s\n' "$BODY" | awk -v h="$WANT" -v sec="$SECTION_FILE" '
    function dump() { while ((getline l < sec) > 0) print l; close(sec) }
    {
      raw = $0
      l = raw; sub(/[ \t]+$/, "", l)
      isfence = (l ~ /^ {0,3}(```|~~~)/)
      if (!infence && skipping && l ~ /^## /) skipping = 0
      # The blank line after dump() is not decoration: the old section owned the
      # blank line that separated it from the next heading, so replacing it
      # without one leaves `## Next heading` butted against the last list item.
      if (!infence && !skipping && l == h) { dump(); print ""; skipping = 1; next }
      if (isfence) infence = !infence
      if (!skipping) print raw
    }
  '
  exit 0
fi

# Absent: insert before the anchor, else append.
printf '%s\n' "$BODY" | awk -v a="$ANCHOR" -v sec="$SECTION_FILE" '
  function dump() { while ((getline l < sec) > 0) print l; close(sec) }
  {
    raw = $0
    l = raw; sub(/[ \t]+$/, "", l)
    isfence = (l ~ /^ {0,3}(```|~~~)/)
    if (!infence && !done && l == a) { dump(); print ""; done = 1 }
    if (isfence) infence = !infence
    print raw
  }
  END { if (!done) { print ""; dump() } }
'
