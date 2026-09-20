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
