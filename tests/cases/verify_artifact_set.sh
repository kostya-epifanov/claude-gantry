#!/usr/bin/env bash
#
# scripts/verify.sh holds the artifact set at five. review.md and qa.md joined
# task.md, plan.md and handover.md in 0.7.0, and every `ensure_excluded.sh` call
# under skills/ that names one of /task.md, /review.md or /qa.md must name all
# three — otherwise the next artifact drifts in one call site at a time and a
# run commits it through `git add -A`. This is the same shape as the
# frontmatter-parser diff: a convention turned into a check.
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

FAIL_LINE='FAIL  an ensure_excluded.sh call names some root artifacts and not the others'

repo="$(mkrepo artifact-set)"
mkdir -p "$repo/skills/one" "$repo/skills/two" "$repo/docs"
printf 'Notes.\n' > "$repo/docs/notes.md"
printf '#!/usr/bin/env bash\necho ok\n' > "$repo/ok.sh"

# One call that names all five, one that names four — the drift case that
# predates qa.md.
cat > "$repo/skills/one/SKILL.md" <<'EOF'
# one
bash "$GANTRY/lib/ensure_excluded.sh" /task.md /plan.md /handover.md /review.md /qa.md
EOF
cat > "$repo/skills/two/SKILL.md" <<'EOF'
# two
bash "$GANTRY/lib/ensure_excluded.sh" /task.md /plan.md /handover.md /review.md
EOF
commit_all "$repo" "fixture"

run_verify "$repo"
assert_contains "$VERIFY_OUT" "$FAIL_LINE" \
  "a call naming /task.md and /review.md without /qa.md fails the artifact-set check"
assert_contains "$VERIFY_OUT" 'skills/two/SKILL.md' "and the check names the offending file"
assert_not_contains "$VERIFY_OUT" 'skills/one/SKILL.md' "the five-name call is not reported"

# The older drift: /task.md without /review.md.
cat > "$repo/skills/two/SKILL.md" <<'EOF'
# two
bash "$GANTRY/lib/ensure_excluded.sh" /task.md /plan.md /handover.md /qa.md
EOF
run_verify "$repo"
assert_contains "$VERIFY_OUT" "$FAIL_LINE" "a call naming /task.md without /review.md fails too"

# The other direction: /qa.md alone is the same drift.
cat > "$repo/skills/two/SKILL.md" <<'EOF'
# two
bash "$GANTRY/lib/ensure_excluded.sh" /qa.md .claude/artifacts/
EOF
run_verify "$repo"
assert_contains "$VERIFY_OUT" "$FAIL_LINE" "a call naming /qa.md without the others fails too"

# A call that names none of them — the journal/artifacts-only shape — is not
# this check's business.
cat > "$repo/skills/two/SKILL.md" <<'EOF'
# two
bash "$GANTRY/lib/ensure_excluded.sh" journal.jsonl .claude/artifacts/
EOF
run_verify "$repo"
assert_not_contains "$VERIFY_OUT" "$FAIL_LINE" "a call naming no root artifact passes"
assert_contains "$VERIFY_OUT" 'ok    every call names all or none' "and the check reports ok"

# --- the array and the exclusions are the same contract, twice --------------
#
# lib/worktree_artifacts.sh's ROOT_ARTIFACTS decides what the prune archive
# copies out of a worktree before destroying it; the `ensure_excluded.sh` calls
# decide what stays out of git. Drift either way is silent: a name excluded but
# not archived is an artifact `git worktree remove` deletes for good, and a name
# archived but not excluded is one `git add -A` commits into the pull request.
#
# The fixture's skills/one names all five, so the exclusion side of the
# comparison is fixed and the array is what moves.
cat > "$repo/skills/one/SKILL.md" <<'EOF'
# one
bash "$GANTRY/lib/ensure_excluded.sh" /task.md /plan.md /handover.md /review.md /qa.md
EOF
rm -f "$repo/skills/two/SKILL.md"
mkdir -p "$repo/lib"
cat > "$repo/lib/worktree_artifacts.sh" <<'EOF'
#!/usr/bin/env bash
ROOT_ARTIFACTS=(task.md plan.md handover.md review.md qa.md)
RUN_ARTIFACTS=(journal.jsonl .claude/artifacts/)
echo "${ROOT_ARTIFACTS[0]} ${RUN_ARTIFACTS[0]}"
EOF
run_verify "$repo"
assert_contains "$VERIFY_OUT" 'ok    /handover.md /plan.md /qa.md /review.md /task.md' \
  "an array that matches the exclusions passes, and the check prints the set"

# A sixth artifact added to the array alone — the archive would copy a file
# nothing keeps out of git.
cat > "$repo/lib/worktree_artifacts.sh" <<'EOF'
#!/usr/bin/env bash
ROOT_ARTIFACTS=(task.md plan.md handover.md review.md qa.md notes.md)
RUN_ARTIFACTS=(journal.jsonl .claude/artifacts/)
echo "${ROOT_ARTIFACTS[0]} ${RUN_ARTIFACTS[0]}"
EOF
run_verify "$repo"
assert_contains "$VERIFY_OUT" 'FAIL  ROOT_ARTIFACTS and the ensure_excluded.sh arguments have diverged' \
  "a name in the array that no call excludes is a red check"
assert_contains "$VERIFY_OUT" '/notes.md' "and the diff names it"

# The other direction: a name excluded but missing from the array is the
# artifact a prune would delete without archiving.
cat > "$repo/skills/one/SKILL.md" <<'EOF'
# one
bash "$GANTRY/lib/ensure_excluded.sh" /task.md /plan.md /handover.md /review.md /qa.md /notes.md /extra.md
EOF
cat > "$repo/lib/worktree_artifacts.sh" <<'EOF'
#!/usr/bin/env bash
ROOT_ARTIFACTS=(task.md plan.md handover.md review.md qa.md notes.md)
RUN_ARTIFACTS=(journal.jsonl .claude/artifacts/)
echo "${ROOT_ARTIFACTS[0]} ${RUN_ARTIFACTS[0]}"
EOF
run_verify "$repo"
assert_contains "$VERIFY_OUT" 'FAIL  ROOT_ARTIFACTS and the ensure_excluded.sh arguments have diverged' \
  "an excluded name missing from the array is a red check too"
assert_contains "$VERIFY_OUT" '/extra.md' "and the diff names that one"

# An unreadable array is reported as unreadable, never as agreement.
printf '#!/usr/bin/env bash\necho nothing here\n' > "$repo/lib/worktree_artifacts.sh"
run_verify "$repo"
assert_contains "$VERIFY_OUT" 'FAIL  could not read ROOT_ARTIFACTS' \
  "a file with no ROOT_ARTIFACTS array fails rather than passing vacuously"

# review.md and qa.md tracked at the root are red, like the other three.
printf '# Review\n' > "$repo/review.md"
printf '# QA\n' > "$repo/qa.md"
commit_all "$repo" "track the verdict files by mistake"
run_verify "$repo"
assert_contains "$VERIFY_OUT" 'committed at the repo root: review.md qa.md' \
  "tracked review.md and qa.md at the root fail the not-tracked check"

finish
