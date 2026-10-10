#!/usr/bin/env bash
#
# Every pull-request body a skill sends with `gh pr create` or `gh pr edit` goes
# as a file inside the checkout: `--body-file .claude/artifacts/<name>`, a
# relative path, removed by a fenced `rm -f` in the same file once it is used.
#
# Why a file at all. An inline `--body "<body>"` does not survive shell quoting
# once the body carries backticks, quotes and headings, so a model following
# the skill writes the body somewhere and passes `--body-file`. Left to itself
# it picks /tmp or its scratchpad — and a body file from outside the repository
# is an upload of a local file by path, which a privileged-command gate is right
# to put in front of a human. One phone tap per pull request, for prose.
#
# Why these rules exactly. Such a gate can only trust a path it can see stays
# in the checkout: relative, no leading `/`, no `~`, no `..`, no `$` it would
# have to expand, nothing under `.git/` (remote URLs can carry tokens), and no
# `cd` in the same command, which would move what "relative" means. Those are
# the conditions this scanner enforces on the documented commands.
#
# WHAT IT SCANS. Fenced lines in every skills/**/*.md, found with `find` —
# bash 3.2 has no globstar, so `**` would silently skip references/. Prose
# outside a fence may name `--body` freely.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

SKILLS_DIR="$GANTRY_ROOT/skills"

# ONE scanner, used by the real check and by its own negative controls below.
# Prints one line per offence, then `BODYFILES:<n>` — the number of body-file
# commands it found, so a check can refuse to pass vacuously.
scan_body_files() {  # scan_body_files <file>
  awk -v file="$1" '
    /^[[:space:]]*(```|~~~)/ { infence = !infence; buf = ""; next }
    !infence { next }
    # A `\` continuation is one command: join it before judging, or a body
    # flag on the second line escapes the `gh pr` match on the first.
    /\\[[:space:]]*$/ { sub(/\\[[:space:]]*$/, ""); buf = buf $0 " "; next }
    {
      line = buf $0
      buf = ""
      n = split(line, tok, /[[:space:]]+/)
    }
    line ~ /^[[:space:]]*rm[[:space:]]+-f[[:space:]]+/ {
      for (i = 1; i <= n; i++) if (tok[i] != "rm" && tok[i] != "-f") removed[tok[i]] = 1
      next
    }
    line ~ /gh[[:space:]]+pr[[:space:]]+(create|edit)/ {
      for (i = 1; i <= n; i++) {
        t = tok[i]
        if (t ~ /^[({]*(cd|pushd)$/) bad("cd in the same command")
        if (t == "--body-file" || t == "-F") { val = tok[i + 1]; i++ }
        else if (t ~ /^--body-file=/)        { val = substr(t, 13) }
        else if (t ~ /^(--body|-b)(=|$)/)    { bad("inline body " t); continue }
        else continue
        bodyfiles++
        used[val] = NR
        if (val !~ /^\.claude\/artifacts\//) bad("body file outside .claude/artifacts/: " val)
        if (val ~ /(^\/|~|\.\.|\$|\.git\/)/) bad("body file not provably in the checkout: " val)
      }
    }
    function bad(why) { printf "%s:%d: %s — %s\n", file, NR, line, why }
    END {
      for (v in used) if (!(v in removed))
        printf "%s:%d: body file %s is never removed by a fenced rm -f\n", file, used[v], v
      printf "BODYFILES:%d\n", bodyfiles + 0
    }
  ' "$1"
}

count_of() { printf '%s\n' "$1" | sed -n 's/^BODYFILES://p'; }

offenders="$CASE_TMP/offenders"
: >"$offenders"
scanned=0
ship_count=0
integrate_count=0
while IFS= read -r f; do
  scanned=$((scanned + 1))
  out="$(scan_body_files "$f")"
  printf '%s\n' "$out" | grep -v '^BODYFILES:' >>"$offenders"
  case "$f" in
    "$SKILLS_DIR/ship/SKILL.md")      ship_count="$(count_of "$out")" ;;
    "$SKILLS_DIR/integrate/SKILL.md") integrate_count="$(count_of "$out")" ;;
  esac
done < <(find "$SKILLS_DIR" -type f -name '*.md' | LC_ALL=C sort)

if [ "$scanned" -ge 10 ]; then
  _pass "scanned every skill markdown file, references included ($scanned files)"
else
  _fail "expected the skills tree, scanned $scanned files"
fi

# Per file, not a total: integrate plus one ship line would satisfy "at least
# two", and losing ship's --draft variant would then go unnoticed.
if [ "$ship_count" -ge 2 ]; then
  _pass "ship opens its PR from a body file, plain and --draft ($ship_count)"
else
  _fail "ship: expected at least 2 body-file gh pr commands, found $ship_count"
fi
if [ "$integrate_count" -ge 1 ]; then
  _pass "integrate opens its PR from a body file ($integrate_count)"
else
  _fail "integrate: expected at least 1 body-file gh pr command, found $integrate_count"
fi

if [ -s "$offenders" ]; then
  _fail "a documented gh pr command sends its body from outside the checkout, or never removes it"
  cat "$offenders"
else
  _pass "every body file is relative, under .claude/artifacts/, and removed after use"
fi

# The scanner has to be able to fail — and these controls run the SAME
# scan_body_files the check above used.
probe="$CASE_TMP/probe.md"
{
  printf 'prose naming gh pr create --body "x" and --body-file /tmp/b.md is fine\n\n'
  printf '```bash\n'
  printf 'gh pr create --title "t" --body-file .claude/artifacts/b.md --draft\n'
  printf 'rm -f .claude/artifacts/b.md\n'
  printf '```\n'
} >"$probe"
found="$(scan_body_files "$probe")"
assert_contains "$found" "BODYFILES:1" "the clean shape is counted"
assert_not_contains "$found" " — " "the clean shape, and prose outside a fence, pass"

{
  printf '```bash\n'
  printf 'gh pr create --title t --body-file /tmp/pr-body.md\n'
  printf 'gh pr create --title t --body "inline"\n'
  printf "gh pr edit 3 --body='inline'\n"
  printf 'gh pr create --title t -F ~/body.md\n'
  printf 'gh pr create --title t --body-file=.claude/artifacts/../../x.md\n'
  printf 'gh pr create --title t --body-file .claude/artifacts/$NAME.md\n'
  printf 'cd sub && gh pr create --title t --body-file .claude/artifacts/c.md\n'
  printf 'gh pr create --title t --body-file .claude/artifacts/kept.md\n'
  printf 'rm -f .claude/artifacts/c.md\n'
  printf 'gh pr create --title t \\\n'
  printf '  --body-file /tmp/continued.md\n'
  printf '(cd sub && gh pr create --title t --body-file .claude/artifacts/c.md)\n'
  printf '```\n'
} >"$probe"
found="$(scan_body_files "$probe")"
assert_contains "$found" "outside .claude/artifacts/: /tmp/pr-body.md" "a /tmp body file is caught"
assert_contains "$found" "inline body --body" "an inline --body is caught"
assert_contains "$found" "inline body --body='inline'" "an inline --body= is caught"
assert_contains "$found" "outside .claude/artifacts/: ~/body.md" "-F under ~ is caught"
assert_contains "$found" "not provably in the checkout: .claude/artifacts/../../x.md" "a .. escape is caught"
assert_contains "$found" "not provably in the checkout: .claude/artifacts/\$NAME.md" "a variable path is caught"
assert_contains "$found" "cd in the same command" "a chained cd is caught"
assert_contains "$found" "outside .claude/artifacts/: /tmp/continued.md" "a flag on a continuation line is caught"
assert_contains "$found" "(cd sub && gh pr create --title t --body-file .claude/artifacts/c.md) — cd in the same command" \
  "a cd inside a subshell is caught"
assert_contains "$found" "kept.md is never removed" "a body file with no rm -f is caught"

finish
