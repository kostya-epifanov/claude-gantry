#!/usr/bin/env bash
#
# Every command /gantry:integrate tells the model to run must be FLAT: one
# invocation, with no command substitution, no heredoc, no pipe and no `&&`,
# `||` or `;` chaining.
#
# This is not a style rule. A worktree-isolated session refuses a command whose
# effect it cannot verify stays inside the worktree, and a substitution or a
# compound structure is exactly what it cannot verify — the refusal was observed
# repeatedly while this skill was being written. A skill whose commands are
# refused is a skill that does nothing, and the failure surfaces mid-merge
# rather than at review.
#
# So it is a test rather than a sentence in the SKILL.md, and it runs over
# skills/integrate/**/*.md: the body and its references both carry commands.
#
# WHAT IT SCANS. Lines inside fenced blocks only. The fence markers themselves
# are excluded (they are backticks), and prose outside a fence may name `$(…)`
# or a pipe freely — describing the rule has to stay possible.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

SKILL_DIR="$GANTRY_ROOT/skills/integrate"

assert_path_present "$SKILL_DIR/SKILL.md" "the skill body exists"

offenders="$CASE_TMP/offenders"
: >"$offenders"

# ONE scanner, used by the real check and by its own negative controls below. A
# hand-copied second copy in the controls is how a scanner comes to pass its own
# self-test while the real one has stopped scanning anything.
scan_fences() {  # scan_fences <file> — prints one line per offending command
  awk -v file="$1" '
    /^[[:space:]]*(```|~~~)/ { infence = !infence; next }
    !infence { next }
    {
      line = $0
      bad = ""
      if (index(line, "$(") > 0)                 bad = bad " command-substitution"
      if (index(line, "`") > 0)                  bad = bad " backtick"
      if (index(line, "<<") > 0)                 bad = bad " heredoc"
      if (index(line, "&&") > 0)                 bad = bad " and-chain"
      if (index(line, "||") > 0)                 bad = bad " or-chain"
      if (index(line, "|") > 0)                  bad = bad " pipe"
      if (index(line, ";") > 0)                  bad = bad " semicolon-chain"
      if (bad != "") printf "%s:%d:%s —%s\n", file, NR, line, bad
    }
  ' "$1"
}

scanned=0
for f in "$SKILL_DIR"/SKILL.md "$SKILL_DIR"/references/*.md; do
  [ -f "$f" ] || continue
  scanned=$((scanned + 1))
  scan_fences "$f" >>"$offenders"
done

if [ "$scanned" -ge 2 ]; then
  _pass "scanned the skill body and its references ($scanned files)"
else
  _fail "expected the skill body and at least one reference, scanned $scanned"
fi

if [ -s "$offenders" ]; then
  _fail "a command in skills/integrate is not flat"
  cat "$offenders"
else
  _pass "every fenced command is flat"
fi

# The docs stage (BASE-71) is the one part of the body written after the
# scanner, and it carries more commands than any stage but the loop. The scan
# above already covers it by construction; this cuts the stage out BY HEADING
# (no fence logic — scan_fences stays the only fence parser) and runs the same
# scanner over just that region, so a regression there is named as such rather
# than lost in a whole-file offender list.
docs_region="$CASE_TMP/docs-region.md"
docs_start="$(grep -n '^## Stage [0-9]* — Docs' "$SKILL_DIR/SKILL.md" | head -1 | cut -d: -f1)"
if [ -n "$docs_start" ]; then
  docs_end="$(awk -v start="$docs_start" 'NR > start && /^## Stage/ { print NR; exit }' "$SKILL_DIR/SKILL.md")"
  [ -n "$docs_end" ] || docs_end="$(wc -l <"$SKILL_DIR/SKILL.md" | tr -d ' ')"
  sed -n "${docs_start},${docs_end}p" "$SKILL_DIR/SKILL.md" >"$docs_region"
  # Column zero is where a fenced command sits, but a command written at column
  # zero OUTSIDE a fence sits there too — and scan_fences skips it, so a non-flat
  # one would pass unseen. Proof that every such line is fenced, using the same
  # scanner: append a `;` to each column-zero command and count how many the
  # scanner reports as a semicolon-chain. Unfenced lines go unreported, so the
  # two counts differ exactly when a command has escaped its fence.
  cmd_lines="$(grep -cE '^(git|gh|bash) ' "$docs_region")"
  if [ "$cmd_lines" -gt 0 ]; then
    _pass "the docs stage carries column-zero commands to scan ($cmd_lines)"
  else
    _fail "the docs stage region has no column-zero command — nothing for the scanner to check"
  fi
  fence_probe="$CASE_TMP/docs-fence-probe.md"
  sed -E 's/^((git|gh|bash) .*)$/\1;/' "$docs_region" >"$fence_probe"
  fenced_lines="$(scan_fences "$fence_probe" | grep -c 'semicolon-chain')"
  if [ "$fenced_lines" -eq "$cmd_lines" ]; then
    _pass "every column-zero command in the docs stage is inside a fence"
  else
    _fail "$((cmd_lines - fenced_lines)) column-zero command(s) in the docs stage are outside a fence, where the scanner cannot see them"
  fi
  found="$(scan_fences "$docs_region")"
  if [ -z "$found" ]; then
    _pass "every fenced command in the docs stage is flat"
  else
    _fail "a command in the docs stage is not flat"
    printf '%s\n' "$found"
  fi
else
  _fail "no '## Stage N — Docs' heading in skills/integrate/SKILL.md"
fi

# The scanner has to be able to fail, or it is a green light wired to nothing —
# and these controls run the SAME scan_fences the check above used.
probe="$CASE_TMP/probe.md"
{
  printf 'prose naming $(a substitution) and a | pipe and a; semicolon, which is fine\n\n'
  printf '```bash\n'
  printf 'git rev-parse HEAD\n'
  printf '```\n'
} >"$probe"
found="$(scan_fences "$probe")"
if [ -z "$found" ]; then
  _pass "prose outside a fence is not scanned, and a flat fenced command passes"
else
  _fail "the scanner reached outside a fence: $found"
fi

{
  printf '```bash\n'
  printf 'git log --oneline | head -5\n'
  printf 'echo "$(git rev-parse HEAD)"\n'
  printf 'git add -A && git commit -m x\n'
  printf '```\n'
} >"$probe"
found="$(scan_fences "$probe")"
assert_contains "$found" "pipe" "a fenced pipe is caught"
assert_contains "$found" "command-substitution" "a fenced substitution is caught"
assert_contains "$found" "and-chain" "a fenced && chain is caught"

finish
