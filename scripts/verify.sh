#!/usr/bin/env bash
#
# verify.sh — everything CI runs, in one place, so a green local run means a
# green CI run. Exit 0 = clean.

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

fail=0
ok()   { printf '  ok    %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; fail=1; }
head2() { printf '\n== %s ==\n' "$1"; }

head2 "shell syntax"
while IFS= read -r f; do
  if bash -n "$f" 2>/dev/null; then ok "$f"; else bad "$f"; bash -n "$f"; fi
done < <(git ls-files '*.sh')

head2 "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  git ls-files '*.sh' -z | xargs -0 shellcheck -S warning && ok "shellcheck clean" || bad "shellcheck"
else
  echo "  shellcheck not installed — skipped"
fi

head2 "python"
if command -v python3 >/dev/null 2>&1; then
  while IFS= read -r f; do
    python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$f" \
      && ok "$f" || bad "$f"
  done < <(git ls-files '*.py')
fi

head2 "JSON manifests"
for f in .claude-plugin/plugin.json .claude-plugin/marketplace.json hooks/hooks.json; do
  jq empty "$f" 2>/dev/null && ok "$f" || bad "$f"
done

head2 "plugin manifests validate"
if command -v claude >/dev/null 2>&1; then
  claude plugin validate .claude-plugin/plugin.json      --strict >/dev/null && ok "plugin.json"      || bad "plugin.json"
  claude plugin validate .claude-plugin/marketplace.json --strict >/dev/null && ok "marketplace.json" || bad "marketplace.json"
  claude plugin validate skills --strict >/dev/null && ok "skills" || bad "skills"
  claude plugin validate agents --strict >/dev/null && ok "agents" || bad "agents"
else
  echo "  claude CLI not available — skipped"
fi

head2 "skill frontmatter: name matches its directory"
for d in skills/*/; do
  n="$(basename "$d")"
  got="$(sed -n 's/^name:[[:space:]]*//p' "$d/SKILL.md" | head -1)"
  [ "$got" = "$n" ] && ok "$n" || bad "$n (frontmatter says '$got')"
done

head2 "agent frontmatter: name matches its filename"
for f in agents/*.md; do
  n="$(basename "$f" .md)"
  got="$(sed -n 's/^name:[[:space:]]*//p' "$f" | head -1)"
  [ "$got" = "$n" ] && ok "$n" || bad "$n (frontmatter says '$got')"
done

head2 "no line-number citations (they rot on the first edit)"
out="$(git ls-files '*.md' -z | xargs -0 grep -InE '\.md:[0-9]+' 2>/dev/null)"
[ -z "$out" ] && ok "none" || { bad "line-number citations found"; printf '%s\n' "$out"; }

head2 "no leftovers from the extraction"
out="$(git ls-files -z -- ':!scripts' | xargs -0 grep -InE '\bkit:|\$KIT\b|kit@skills-dir|homebase|raw_specs|OPEN-QUESTIONS|Slice [0-9]' 2>/dev/null)"
[ -z "$out" ] && ok "none" || { bad "pre-rename references survive"; printf '%s\n' "$out"; }

head2 "relative links resolve"
# NB: `grep` exiting 1 on "no matches" is normal here, and under `set -o pipefail`
# it would otherwise be read as a failure. Hence the `|| true`.
badlinks=0
while IFS= read -r f; do
  d="$(dirname "$f")"
  links="$(grep -oE '\]\(([^)#:]+\.md)(#[^)]*)?\)' "$f" 2>/dev/null || true)"
  [ -n "$links" ] || continue
  while IFS= read -r raw; do
    [ -n "$raw" ] || continue
    link="${raw#](}"; link="${link%)}"; link="${link%%#*}"
    if [ ! -e "$d/$link" ]; then
      printf '  FAIL  %s -> %s\n' "$f" "$link"; badlinks=1; fail=1
    fi
  done <<< "$links"
done < <(git ls-files '*.md')
[ "$badlinks" -eq 0 ] && ok "all resolve"

head2 "secret scan"
bash scripts/secret-scan.sh >/dev/null 2>&1 && ok "clean" || { bad "see: bash scripts/secret-scan.sh"; }

printf '\n%s\n' "-----------------------------------------"
if [ "$fail" -eq 0 ]; then echo "verify: PASS"; else echo "verify: FAIL"; fi
exit "$fail"
