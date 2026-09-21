#!/usr/bin/env bash
# check_evals.sh — structural lint of the eval cases, for free.
# Run with: bash check_evals.sh [dir]   (default: evals/ under the repo root)
#
# WHY THIS EXISTS. `claude plugin eval` has no dry-run. The only way to learn
# that a case is malformed is a paid run that spends API credit and then reports
# a parse error instead of a score, and a suite is typically five cases deep
# before anybody runs it. This script is the half of that feedback which costs
# nothing: it reads the case files and refuses the shapes the harness refuses,
# so the gate can hold them without a credential and CI can hold them without a
# CLI.
#
# It is a lint, not a parser. What it checks and what it cannot:
#
#   - YAML is read with grep/sed/awk over a FLAT SUBSET — scalars, one level of
#     nesting, block lists and flow lists (`[a, b]`). Valid YAML outside that
#     subset (anchors, multi-line scalars, deeper nesting) is not understood and
#     is reported as a defect. That is the intended direction of error: a case
#     this script cannot read is a case the next author cannot read either.
#   - Keys are matched by their LEAF NAME, so `max_turns` is found whether it
#     sits under `execution:` in case.yaml or at the top of prompt.md's
#     frontmatter, which is where the harness also accepts it. The cost is that
#     nesting depth is not checked. The harness checks it; this does not.
#   - Unknown keys pass silently. The schema below was read out of the shipped
#     Claude Code binary on 2026-09-20 (schema_version 1.1); a key added after
#     that date must not fail a lint that has never heard of it.
#
# Exit codes: 0 = clean, or no suite at the default path · 1 = at least one
# defect, listed on stdout · 2 = usage, or a check could not be run.

set -uo pipefail

[ "$#" -le 1 ] || { printf 'usage: check_evals.sh [dir]\n' >&2; exit 2; }

# The six grader types and the five tools a case may ask for. Both lists are
# the harness's, not this script's preference: the tools are the ones that need
# no `--allow-tools` grant, so a suite that stays inside them runs with one
# command and nothing executes outside the sandbox.
GRADER_TYPES=' regex tool_order tool_used file_exists llm baseline '
ALLOWED_TOOLS=' Read Grep Glob Agent Skill '
SCHEMA_VERSION='1.1'

# Directory names case discovery always skips — the harness's own list.
SKIP_DIRS=' node_modules .claude results mocks '

explicit=0
if [ "$#" -eq 1 ]; then
  explicit=1
  root="$1"
else
  root="$(git rev-parse --show-toplevel 2>/dev/null)/evals"
fi

if [ ! -d "$root" ]; then
  if [ "$explicit" -eq 1 ]; then
    printf 'check_evals: no such directory: %s\n' "$root" >&2
    exit 2
  fi
  # A repository with no suite is not a repository with a broken suite. This is
  # the branch scripts/verify.sh takes in any checkout that has not added one,
  # and the branch tests/cases/verify_untracked.sh takes in its fixture repo.
  echo "  no eval suite at evals/ — nothing to check"
  exit 0
fi

fail=0
ok()  { printf '  ok    %s\n' "$1"; }
bad() { printf '  FAIL  %s\n' "$1"; fail=1; }

# --- the flat-YAML reader ----------------------------------------------------

# flatten <file> — print `leaf<TAB>value`, one line per scalar and per list
# element, for the flat subset described in the header. Reads a whole file;
# feed it a frontmatter block if that is what you mean.
flatten() {
  awk '
    function emit(k, v) {
      gsub(/^[ \t]+|[ \t]+$/, "", v)
      gsub(/^["\x27]|["\x27]$/, "", v)
      if (k != "" && v != "") printf "%s\t%s\n", k, v
    }
    function flow(k, v,   n, i, parts) {
      sub(/^\[/, "", v); sub(/\]$/, "", v)
      n = split(v, parts, ",")
      for (i = 1; i <= n; i++) emit(k, parts[i])
    }
    /^[ \t]*#/ { next }
    /^[ \t]*$/ { next }
    {
      line = $0
      sub(/[ \t]+#.*$/, "", line)         # a trailing comment is valid YAML
      sub(/[ \t]+$/, "", line)

      # A list element belongs to the key that opened the list.
      if (line ~ /^[ \t]*-[ \t]+/) {
        item = line
        sub(/^[ \t]*-[ \t]+/, "", item)
        emit(lastkey, item)
        next
      }

      if (line !~ /^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*:/) next

      key = line
      sub(/^[ \t]*/, "", key)
      sub(/[ \t]*:.*$/, "", key)

      val = line
      sub(/^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*:[ \t]*/, "", val)

      lastkey = key
      if (val == "") next                 # a section, or a block list follows
      if (val ~ /^\[.*\]$/) { flow(key, val); next }
      emit(key, val)
    }
  ' "$1"
}

# frontmatter <file> — the YAML between the opening and closing `---`.
frontmatter() {
  awk 'NR == 1 && $0 !~ /^---[ \t]*$/ { exit }
       NR == 1 { inside = 1; next }
       inside && /^---[ \t]*$/ { exit }
       inside { print }' "$1"
}

# body_after_frontmatter <file> — everything below the closing `---`, or the
# whole file when there is none.
body_after_frontmatter() {
  awk 'NR == 1 && $0 !~ /^---[ \t]*$/ { all = 1 }
       all { print; next }
       NR == 1 { next }
       !seen && /^---[ \t]*$/ { seen = 1; next }
       seen { print }' "$1"
}

# values <leaf> — every value recorded for a leaf key, one per line.
# Reads $KV, the flattened case set by read_case.
values() {
  printf '%s\n' "$KV" | awk -F'\t' -v k="$1" '$1 == k { print $2 }'
}

# has_key <leaf> — true when the leaf appeared at all, value or not.
has_key() {
  printf '%s\n' "$KEYS" | grep -qx -- "$1"
}

# read_case <dir> — set KV and KEYS from case.yaml plus prompt.md frontmatter.
read_case() {
  local d="$1" kv='' keys=''
  if [ -f "$d/case.yaml" ]; then
    kv="$(flatten "$d/case.yaml")"
    keys="$(awk '/^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*:/ { k=$0; sub(/^[ \t]*/,"",k); sub(/[ \t]*:.*$/,"",k); print k }' "$d/case.yaml")"
  fi
  if [ -f "$d/prompt.md" ]; then
    local fm; fm="$(frontmatter "$d/prompt.md")"
    if [ -n "$fm" ]; then
      kv="$kv
$(printf '%s\n' "$fm" | flatten /dev/stdin)"
      keys="$keys
$(printf '%s\n' "$fm" | awk '/^[ \t]*[A-Za-z_][A-Za-z0-9_]*[ \t]*:/ { k=$0; sub(/^[ \t]*/,"",k); sub(/[ \t]*:.*$/,"",k); print k }')"
    fi
  fi
  KV="$kv"
  KEYS="$keys"
}

# --- the checks --------------------------------------------------------------

check_graders() {  # check_graders <dir> <name>
  local d="$1" name="$2" n=0 g type body
  if [ ! -d "$d/graders" ]; then
    bad "$name: no graders/ directory"
    return
  fi
  for g in "$d"/graders/*.md; do
    [ -f "$g" ] || continue
    n=$((n + 1))
    local rel
    rel="$name/graders/$(basename "$g")"
    if [ -z "$(frontmatter "$g")" ]; then
      # The harness skips a grader file with no frontmatter. A grader that is
      # silently not a grader is worse than one that fails to parse.
      bad "$rel: no frontmatter — the harness ignores this file"
      continue
    fi
    type="$(frontmatter "$g" | flatten /dev/stdin | awk -F'\t' '$1 == "type" { print $2; exit }')"
    if [ -z "$type" ]; then
      bad "$rel: frontmatter has no type:"
      continue
    fi
    case "$GRADER_TYPES" in
      *" $type "*) : ;;
      *) bad "$rel: unknown grader type '$type'"; continue ;;
    esac
    if [ "$type" = llm ] || [ "$type" = baseline ]; then
      body="$(body_after_frontmatter "$g" | tr -d '[:space:]')"
      local crit
      crit="$(frontmatter "$g" | flatten /dev/stdin | awk -F'\t' '$1 == "criteria" { print $2; exit }')"
      if [ -z "$body" ] && [ -z "$crit" ]; then
        bad "$rel: a $type grader needs criteria — as the file's body, or as criteria:"
        continue
      fi
    fi
    ok "$rel ($type)"
  done
  [ "$n" -gt 0 ] || bad "$name: graders/ holds no .md files"
}

check_diffs() {  # check_diffs <dir> <name>
  local d="$1" name="$2" f dir base
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    dir="$(dirname "$f")"; base="$(basename "$f")"
    if command -v git >/dev/null 2>&1; then
      # Inside a repository, `git apply` reads the diff's paths from the
      # repository root and silently SKIPS every one outside the current
      # directory — exit 0 on a fixture that has drifted completely. The
      # ceiling stops discovery at the fixture, so the paths are read from it.
      if (cd "$dir" && GIT_CEILING_DIRECTORIES="$(dirname "$PWD")" \
            git apply --check -R "$base" >/dev/null 2>&1); then
        ok "$name: $base reverse-applies to the tree beside it"
      else
        # A diff that has drifted from its tree turns a CORRECT review finding
        # ("this diff does not match these files") into a scored failure.
        bad "$name: $base does not reverse-apply to the tree beside it — the fixture and the diff have drifted apart"
      fi
    elif command -v patch >/dev/null 2>&1; then
      if (cd "$dir" && patch --dry-run -R -p1 <"$base" >/dev/null 2>&1); then
        ok "$name: $base reverse-applies (checked with patch)"
      else
        bad "$name: $base does not reverse-apply to the tree beside it"
      fi
    else
      printf 'check_evals: neither git nor patch is available to check %s\n' "$f" >&2
      exit 2
    fi
  done <<EOF
$(find "$d" -type f -name 'change.diff' | sort)
EOF
}

check_case() {  # check_case <dir>
  local d="$1" name; name="$(basename "$d")"

  if [ ! -f "$d/case.yaml" ] && [ ! -f "$d/prompt.md" ]; then
    bad "$name: neither case.yaml nor prompt.md — the harness does not see this as a case"
    return
  fi

  read_case "$d"

  local sv; sv="$(values schema_version | head -1)"
  if [ -f "$d/case.yaml" ] && [ -z "$sv" ]; then
    bad "$name: case.yaml has no schema_version"
  elif [ -n "$sv" ] && [ "$sv" != "$SCHEMA_VERSION" ]; then
    bad "$name: schema_version is '$sv', this lint knows $SCHEMA_VERSION"
  fi

  local cname; cname="$(values name | head -1)"
  if [ -f "$d/case.yaml" ]; then
    if [ -z "$cname" ]; then
      bad "$name: case.yaml has no name"
    elif [ "$cname" != "$name" ]; then
      bad "$name: case.yaml says name: $cname — --case filters by this, so it must match the directory"
    fi
  fi

  # A prompt is what the harness runs. An empty prompt.md is a case that costs
  # a run and grades nothing.
  if [ -f "$d/prompt.md" ]; then
    [ -n "$(body_after_frontmatter "$d/prompt.md" | tr -d '[:space:]')" ] \
      || bad "$name: prompt.md has no body"
  elif ! has_key prompt; then
    bad "$name: no prompt.md and no prompt: in case.yaml"
  fi

  has_key max_turns       || bad "$name: no max_turns — every case declares a turn bound"
  has_key timeout_seconds || bad "$name: no timeout_seconds — every case declares a time bound"

  if ! has_key allowed_tools; then
    bad "$name: no allowed_tools — declare them rather than inheriting a default"
  else
    local t
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      case "$ALLOWED_TOOLS" in
        *" $t "*) : ;;
        *) bad "$name: allowed_tools has '$t' — outside {Read, Grep, Glob, Agent, Skill}, so the suite would need --allow-tools" ;;
      esac
    done <<EOF
$(values allowed_tools)
EOF
  fi

  # --scaffold runs author-supplied bash as the operator, outside the sandbox.
  # No case here needs it, and the whole suite running without it is what makes
  # `claude plugin eval .` a single safe command.
  has_key scaffold_script \
    && bad "$name: declares scaffold_script — the suite must run without --scaffold"

  local a
  while IFS= read -r a; do
    [ -n "$a" ] || continue
    [ -d "$d/$a" ] || bad "$name: add_dirs names '$a', which is not a directory in the case"
  done <<EOF
$(values add_dirs)
EOF

  check_graders "$d" "$name"
  check_diffs "$d" "$name"
}

cases=0
for dir in "$root"/*/; do
  [ -d "$dir" ] || continue
  base="$(basename "$dir")"
  case "$SKIP_DIRS" in
    *" $base "*) continue ;;
  esac
  cases=$((cases + 1))
  check_case "${dir%/}"
done

if [ "$cases" -eq 0 ]; then
  echo "  no cases under $root — nothing to check"
  exit 0
fi

printf '\n'
if [ "$fail" -eq 0 ]; then
  printf 'check_evals: %s case(s) OK\n' "$cases"
else
  printf 'check_evals: defects above.\n'
fi
exit "$fail"
