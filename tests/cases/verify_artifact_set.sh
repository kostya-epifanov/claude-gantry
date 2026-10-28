#!/usr/bin/env bash
#
# scripts/verify.sh holds the artifact set at four. review.md joined task.md,
# plan.md and handover.md in 0.7.0, and every `ensure_excluded.sh` call under
# skills/ that names /task.md must also name /review.md — otherwise the next
# artifact drifts in one call site at a time and a run commits it through
# `git add -A`. This is the same shape as the frontmatter-parser diff: a
# convention turned into a check.
#
# Like verify_untracked.sh, the fixture is built under $CASE_TMP so verify.sh's
# `cd "$(git rev-parse --show-toplevel)"` resolves to the fixture, and the
# signal is one named check's own line, not the script's exit code.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

VERIFY="$GANTRY_ROOT/scripts/verify.sh"

run_verify() {  # run_verify <repo> — sets VERIFY_OUT
  VERIFY_OUT="$(cd "$1" && bash "$VERIFY" 2>&1)"
  return 0
}

repo="$(mkrepo artifact-set)"
mkdir -p "$repo/skills/one" "$repo/skills/two" "$repo/docs"
printf 'Notes.\n' > "$repo/docs/notes.md"
printf '#!/usr/bin/env bash\necho ok\n' > "$repo/ok.sh"

# One call that names all four, one that names three — the drift case.
cat > "$repo/skills/one/SKILL.md" <<'EOF'
# one
bash "$GANTRY/lib/ensure_excluded.sh" /task.md /plan.md /handover.md /review.md
EOF
cat > "$repo/skills/two/SKILL.md" <<'EOF'
# two
bash "$GANTRY/lib/ensure_excluded.sh" /task.md /plan.md /handover.md
EOF
commit_all "$repo" "fixture"

run_verify "$repo"
assert_contains "$VERIFY_OUT" 'FAIL  an ensure_excluded.sh call names one root artifact and not the other' \
  "a call naming /task.md without /review.md fails the artifact-set check"
assert_contains "$VERIFY_OUT" 'skills/two/SKILL.md' "and the check names the offending file"
assert_not_contains "$VERIFY_OUT" 'skills/one/SKILL.md' "the four-name call is not reported"

# The other direction: /review.md without /task.md is the same drift.
cat > "$repo/skills/two/SKILL.md" <<'EOF'
# two
bash "$GANTRY/lib/ensure_excluded.sh" /review.md .claude/artifacts/
EOF
run_verify "$repo"
assert_contains "$VERIFY_OUT" 'FAIL  an ensure_excluded.sh call names one root artifact and not the other' \
  "a call naming /review.md without /task.md fails too"

# A call that names neither — the journal/artifacts-only shape — is not this
# check's business.
cat > "$repo/skills/two/SKILL.md" <<'EOF'
# two
bash "$GANTRY/lib/ensure_excluded.sh" journal.jsonl .claude/artifacts/
EOF
run_verify "$repo"
assert_not_contains "$VERIFY_OUT" 'FAIL  an ensure_excluded.sh call names one root artifact and not the other' \
  "a call naming neither artifact passes"
assert_contains "$VERIFY_OUT" 'ok    every call names both or neither' "and the check reports ok"

# review.md tracked at the root is red, like the other three.
printf '# Review\n' > "$repo/review.md"
commit_all "$repo" "track review.md by mistake"
run_verify "$repo"
assert_contains "$VERIFY_OUT" 'committed at the repo root: review.md' \
  "a tracked review.md at the root fails the not-tracked check"

finish
