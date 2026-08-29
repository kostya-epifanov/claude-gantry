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

head2 "the duplicated frontmatter parser has not drifted"
# hooks/readiness-gate.sh and lib/detect_stage.sh both parse task.md's
# `status:`. The hook decides whether to BLOCK a stop on it; the detector
# decides which phase to report. They are duplicated on purpose — the hook must
# carry no runtime dependency it could fail to resolve — so the guarantee that
# they agree has to be a check rather than a convention.
extract_fm() { awk '/^frontmatter_status\(\) \{/{f=1} f{print} f && /^\}$/{exit}' "$1"; }
fm_hook="$(extract_fm hooks/readiness-gate.sh)"
fm_lib="$(extract_fm lib/detect_stage.sh)"
if [ -z "$fm_hook" ] || [ -z "$fm_lib" ]; then
  bad "frontmatter_status() not found in both files"
elif [ "$fm_hook" = "$fm_lib" ]; then
  ok "identical"
else
  bad "hooks/readiness-gate.sh and lib/detect_stage.sh have diverged"
  diff <(printf '%s\n' "$fm_hook") <(printf '%s\n' "$fm_lib") || true
fi

head2 "the task template and its example agree"
# examples/task.md is the copy a user reads; skills/plan/templates/task.md is the one the skill
# writes from. They are the same file for a reason — an example that has drifted from the template
# teaches the wrong shape.
if [ ! -f examples/task.md ] || [ ! -f skills/plan/templates/task.md ]; then
  bad "one of examples/task.md or skills/plan/templates/task.md is missing"
elif diff -q examples/task.md skills/plan/templates/task.md >/dev/null 2>&1; then
  ok "identical"
else
  bad "examples/task.md and skills/plan/templates/task.md have diverged"
  diff examples/task.md skills/plan/templates/task.md || true
fi

head2 "the readiness hook resolves the same ROOT the detector does"
# The parser these two share is diffed above, because "if the two ever
# disagreed ... the gate would silently stop arming". They can disagree without
# the parser drifting at all: read the same field out of two different files
# and you get the same failure. That is what happened -- the hook took ROOT
# from $CLAUDE_PROJECT_DIR while lib/detect_stage.sh took it from `git
# rev-parse --show-toplevel`, so on a worktree run the hook read the MAIN
# checkout's task.md and skipped forever, on gantry's own default workflow.
#
# So this asserts the behaviour rather than the line: build a repo whose main
# checkout says `shipped` and whose worktree says `implementing` over a red
# gate, point $CLAUDE_PROJECT_DIR at the main checkout the way a session
# launched there would, and require the hook to block.
hookdir="$(mktemp -d)"
trap 'rm -rf "$hookdir"' EXIT
(
  cd "$hookdir" || exit 1
  mkdir -p main && cd main || exit 1
  git init -q .
  git config user.email v@example.com
  git config user.name verify
  mkdir -p .claude
  printf '#!/usr/bin/env bash\nexit 1\n' > .claude/gates.sh   # always red
  printf -- '---\nstatus: shipped\n---\n' > task.md
  git add -A && git commit -qm base
  git worktree add -q ../wt -b wt
  printf -- '---\nstatus: implementing\n---\n' > ../wt/task.md
) >/dev/null 2>&1 || bad "could not build the hook fixture"

hook_rc() {  # hook_rc <cwd> ; echoes the hook's exit code
  printf '{"cwd":"%s","hook_event_name":"Stop","stop_hook_active":false}' "$1" \
    | CLAUDE_PROJECT_DIR="$hookdir/main" bash "$PWD/hooks/readiness-gate.sh" >/dev/null 2>&1
  echo $?
}

got="$(hook_rc "$hookdir/wt")"
[ "$got" = "2" ] \
  && ok "blocks on a worktree whose task.md says implementing (exit 2)" \
  || bad "worktree run: got exit $got, want 2 — the hook is reading the wrong root again"

printf -- '---\nstatus: shipped\n---\n' > "$hookdir/wt/task.md"
got="$(hook_rc "$hookdir/wt")"
[ "$got" = "0" ] \
  && ok "stays inert on a worktree whose task.md says shipped (exit 0)" \
  || bad "worktree inert case: got exit $got, want 0"

# The fallback chain must be untouched: no cwd in the payload means the hook
# still answers from $CLAUDE_PROJECT_DIR exactly as it did before.
printf -- '---\nstatus: implementing\n---\n' > "$hookdir/main/task.md"
got="$(printf '{"hook_event_name":"Stop","stop_hook_active":false}' \
  | CLAUDE_PROJECT_DIR="$hookdir/main" bash "$PWD/hooks/readiness-gate.sh" >/dev/null 2>&1; echo $?)"
[ "$got" = "2" ] \
  && ok "falls back to \$CLAUDE_PROJECT_DIR when the payload carries no cwd" \
  || bad "fallback case: got exit $got, want 2"

rm -rf "$hookdir"; trap - EXIT

head2 "secret scan"
bash scripts/secret-scan.sh >/dev/null 2>&1 && ok "clean" || { bad "see: bash scripts/secret-scan.sh"; }

printf '\n%s\n' "-----------------------------------------"
if [ "$fail" -eq 0 ]; then echo "verify: PASS"; else echo "verify: FAIL"; fi
exit "$fail"
