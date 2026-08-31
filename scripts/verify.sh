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

# Every enumeration below goes through this, and the flags are the whole point.
#
# `git ls-files` on its own lists TRACKED files only, which made this gate blind
# to precisely the files a gantry run creates. `implement` runs the gate while
# `task.md` and `plan.md` are still untracked; `ship` commits them minutes later;
# CI then runs this same script with them tracked. Green here, red there, on the
# pipeline's own artifacts. A `lib/*.sh` written during `implement` had the same
# hole — never parsed or shellchecked until after it was pushed.
#
# `--others --exclude-standard` closes it: files that are new get checked, files
# that are ignored do not. `--exclude-standard` honours three sources, and the
# difference between them matters here. `.gitignore` is tracked, so it is the
# half that still holds on a fresh CI checkout; each clone's
# `.git/info/exclude` is local, and is where the drivers put a run's own noise;
# and `core.excludesFile`, the contributor's global ignore, is neither — it
# varies per machine, so two contributors can enumerate different file sets from
# the same tree. That last one is benign for the green-local-means-green-CI
# claim, since a globally ignored file never reaches CI either, but it does mean
# this gate's coverage is not identical everywhere. `.gitignore` and
# `.git/info/exclude` both list `journal.jsonl` and `.claude/artifacts/`, so a
# run's own journal and gate transcripts stay out of every sweep below.
#
# The price is real and is documented in CONTRIBUTING: this gate's result now
# depends on what untracked files happen to be sitting in the tree, so a RED run
# here no longer implies a red run in CI. The remedy for a false red is to ignore
# the path, never to narrow this enumeration.
repo_files() { git ls-files --cached --others --exclude-standard "$@"; }

head2 "shell syntax"
while IFS= read -r f; do
  if bash -n "$f" 2>/dev/null; then ok "$f"; else bad "$f"; bash -n "$f"; fi
done < <(repo_files '*.sh')

head2 "shellcheck"
if command -v shellcheck >/dev/null 2>&1; then
  repo_files '*.sh' -z | xargs -0 shellcheck -S warning && ok "shellcheck clean" || bad "shellcheck"
else
  echo "  shellcheck not installed — skipped"
fi

head2 "python"
if command -v python3 >/dev/null 2>&1; then
  while IFS= read -r f; do
    python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$f" \
      && ok "$f" || bad "$f"
  done < <(repo_files '*.py')
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
out="$(repo_files '*.md' -z | xargs -0 grep -InE '\.md:[0-9]+' 2>/dev/null)"
[ -z "$out" ] && ok "none" || { bad "line-number citations found"; printf '%s\n' "$out"; }

head2 "no leftovers from the extraction"
out="$(repo_files -z -- ':!scripts' | xargs -0 grep -InE '\bkit:|\$KIT\b|kit@skills-dir|homebase|raw_specs|OPEN-QUESTIONS|Slice [0-9]' 2>/dev/null)"
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
done < <(repo_files '*.md')
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

head2 "always-on context budget"
# Skill and agent descriptions are loaded into every session whether or not
# anything fires, so the cost is invisible while you write and permanent once
# you ship. This is that cost as an exit code; see the script's header for why
# it counts characters rather than asking the CLI for tokens.
if bash scripts/context_budget.sh >/dev/null 2>&1; then
  ok "within budget"
else
  bad "see: bash scripts/context_budget.sh"
fi

head2 "gate and hook behaviour"
# The two scripts that carry this project's one guarantee — lib/run_gates.sh
# and hooks/readiness-gate.sh — executed against throwaway fixture repos. Every
# check above this line proves the shell *parses*; only this one proves the gate
# ever blocked anything. Run `bash tests/run.sh` directly for the per-case
# detail; here we only need the verdict.
if bash tests/run.sh >/dev/null 2>&1; then
  ok "all cases pass"
else
  bad "see: bash tests/run.sh"
fi

head2 "detect_stage.sh reads Open questions correctly"
# lib/detect_stage.sh's FORKS: line is the only machine-checkable half of the
# rule that a fork must be settled before an implementer is dispatched. Two of
# these cases are load-bearing rather than thorough:
#   - "unchecked boxes in Acceptance criteria" is the catastrophic failure. A
#     parser that leaked out of its own section would report every task.md as
#     open and block every run, forever.
#   - "unchecked box inside a fence" is what lets the task template show the
#     convention without every task.md written from it reading as open.
# Both would ship green without an assertion here.
LIB="$PWD/lib/detect_stage.sh"
fixdir="$(mktemp -d)"
# `mktemp -d` can fail — a full or read-only TMPDIR, or a sandboxed session that
# denies it — and every line below then operates on the empty string. This is
# not theoretical: three lanes hit it in one batch. `cd ""` SUCCEEDS in bash, so
# the subshell keeps the repository as its cwd and `git init -q .` runs in the
# repository itself; `rm -f "$fixdir/task.md"` becomes `rm -f /task.md`, each
# `printf > "$fixdir/task.md"` writes to `/task.md`, and the EXIT trap becomes
# `rm -rf ""`. Where those writes are permitted, the fixture assertions then
# rerun the detector against the REAL task.md and pass or fail for reasons that
# have nothing to do with the parser — a false green as easily as a false red.
#
# So this is exit 2 (the gate could not run) rather than exit 1 (the gate found
# a defect), and it is checked before the trap that would otherwise `rm -rf ""`.
[ -n "$fixdir" ] && [ -d "$fixdir" ] || {
  bad "could not create the fixture repo: mktemp -d produced no directory"
  exit 2
}
trap 'rm -rf "$fixdir"' EXIT
(
  cd "$fixdir" || exit 1
  git init -q . 2>/dev/null
  git config user.email f@example.com; git config user.name fixture
) || bad "could not create the fixture repo"

forks_is() {   # forks_is <expected> <label>; task.md must already be in place
  local want="$1" label="$2" got
  got="$(cd "$fixdir" && bash "$LIB" 2>/dev/null | sed -n 's/^FORKS://p')"
  [ "$got" = "$want" ] && ok "$label -> $want" || bad "$label -> got '$got', want '$want'"
}

rm -f "$fixdir/task.md"
forks_is absent "no task.md"

printf '# t\n\n## Context\n\nprose.\n' > "$fixdir/task.md"
forks_is unknown "task.md with no Open questions heading"

printf '# t\n\n## Open questions\n\n- [ ] which database?\n' > "$fixdir/task.md"
forks_is open "one unchecked box"

printf '# t\n\n## Open questions\n\n- which database?\n' > "$fixdir/task.md"
forks_is open "a bare bullet with no box"

printf '# t\n\n## Open questions\n\n- [x] settled: postgres.\n' > "$fixdir/task.md"
forks_is none "only checked boxes"

printf '# t\n\n## Open questions\n\nNone.\n' > "$fixdir/task.md"
forks_is none "prose only, no bullets"

printf '# t\n\n## Open questions\n\n```\n- [ ] this is an example, not a fork\n```\n' > "$fixdir/task.md"
forks_is none "unchecked box inside a fenced block"

printf '# t\n\n## Acceptance criteria\n\n- [ ] not a fork\n- [ ] also not a fork\n\n## Open questions\n\n- [x] settled.\n' > "$fixdir/task.md"
forks_is none "unchecked boxes in Acceptance criteria, settled Open questions"

printf '# t\n\n## Open questions\n\n- [ ] last section, terminated by EOF\n' > "$fixdir/task.md"
forks_is open "section last in the file, EOF-terminated"

printf '# t\n\n## OPEN QUESTIONS\n\n- [ ] heading case must not matter\n' > "$fixdir/task.md"
forks_is open "heading matched case-insensitively"

printf '# t\n\n## Open questions\n\n  - [ ] nested under a parent\n' > "$fixdir/task.md"
forks_is open "an indented/nested item still counts"

# Every case below reported `none` before /code-review caught them — i.e. an
# undecided fork reading as settled, which dispatches an implementer against it.
# The parser must fail closed, so these are the regression net for that.
printf '# t\n\n## Open questions\n\n1. [ ] an ordered list is still a list\n' > "$fixdir/task.md"
forks_is open "ordered list, 1. marker"

printf '# t\n\n## Open questions\n\n1) [ ] an ordered list is still a list\n' > "$fixdir/task.md"
forks_is open "ordered list, 1) marker"

printf '# t\n\n## Open questions\n\n-[ ] no space after the bullet\n' > "$fixdir/task.md"
forks_is open "a missing space after the marker is a typo, not a decision"

printf '# t\n\n## Open questions\n\n> - [ ] quoted from somewhere else\n' > "$fixdir/task.md"
forks_is open "a blockquoted item still counts"

printf '# t\n\n## Open questions ##\n\n- [ ] fork\n' > "$fixdir/task.md"
forks_is open "heading with a closing ATX run"

printf '# t\n\n## Open questions:\n\n- [ ] fork\n' > "$fixdir/task.md"
forks_is open "heading with a trailing colon"

printf '# t\n\n## **Open questions**\n\n- [ ] fork\n' > "$fixdir/task.md"
forks_is open "heading wrapped in bold"

printf '# t\n\n## Open questions\n\n---\n\nNone.\n' > "$fixdir/task.md"
forks_is none "a horizontal rule is not a list item"

printf '# t\n\n## Open questions\n\n1. [x] settled\n' > "$fixdir/task.md"
forks_is none "a checked ordered item is settled"

cp skills/plan/templates/task.md "$fixdir/task.md"
forks_is none "a task.md freshly copied from the template"

rm -rf "$fixdir"; trap - EXIT

head2 "secret scan"
bash scripts/secret-scan.sh >/dev/null 2>&1 && ok "clean" || { bad "see: bash scripts/secret-scan.sh"; }

printf '\n%s\n' "-----------------------------------------"
if [ "$fail" -eq 0 ]; then echo "verify: PASS"; else echo "verify: FAIL"; fi
exit "$fail"
