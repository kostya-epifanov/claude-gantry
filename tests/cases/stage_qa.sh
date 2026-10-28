#!/usr/bin/env bash
#
# detect_stage.sh's E2E:, QA:, QA_ROLE: and QA_ENV: lines are what gantry:qa
# routes on and what gantry:ship composes two fixed headings from — "Exercised
# by this run" for a scenario the qa phase ran, "Not proven by this run" for a
# declared scenario nobody ran. The headings exist so that their absence is
# information, which only holds if the lines underneath are facts rather than
# readings; hence these assertions.
#
# The load-bearing cases:
#
#   - the task template's sample scenario is commented out, and a comment is
#     not an entry. A live placeholder would make every task.md written from
#     the template report `present` and put a scenario called "scenario name"
#     under "Not proven" on every pull request — the same failure human_only's
#     placeholder had before it was commented.
#
#   - `e2e:` with `setup:` and an empty `scenarios:` is `none`, not `present`:
#     setup is not a scenario, and reading it as one would disclose a scenario
#     that does not exist.
#
#   - a qa.md whose outcome line is unreadable is `unknown`, which ship reads as
#     "not exercised" — the permissive direction, same as the other parsers.
#
#   - PHASE: is still the last line. Every other assertion here is a substring
#     test over the whole of STAGE_OUT, so all of them would pass equally for a
#     line appended AFTER PHASE:, which would break the output contract.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

repo="$(mkrepo qa)"

e2e_is() {  # e2e_is <expected> <label>; task.md must already be in place
  run_stage "$repo"
  assert_contains "$STAGE_OUT" "E2E:$1" "$2 -> E2E:$1"
}

qa_is() {  # qa_is <expected> <label>; qa.md must already be in place (or not)
  run_stage "$repo"
  assert_contains "$STAGE_OUT" "QA:$1" "$2 -> QA:$1"
}

# --- E2E: the three states ship routes on -------------------------------------

write_task_raw "$repo" <<'MD'
---
status: reviewed
---

## How to verify

```yaml
verification:
  automated:
    lint: true
    e2e:
      setup: { use_profile: true }
      scenarios:
        - name: "submit the form"
          goal: "a filled form posts and the thanks page shows"
          steps: []
  human_only:
    # - "nothing"
```
MD
e2e_is present "a populated scenarios list in the canonical fenced block"

write_task_raw "$repo" <<'MD'
---
status: reviewed
---

```yaml
verification:
  automated:
    e2e:
      setup: { use_profile: true }
      scenarios:
```
MD
e2e_is none "e2e with setup and an empty scenarios key"

write_task_raw "$repo" <<'MD'
---
status: reviewed
---

```yaml
verification:
  automated:
    e2e:
      scenarios: []
```
MD
e2e_is none "an empty inline list"

write_task_raw "$repo" <<'MD'
---
status: reviewed
---

```yaml
verification:
  automated:
    e2e:
      scenarios: [{ name: "a", goal: "b" }]
```
MD
e2e_is present "a populated inline list"

write_task_raw "$repo" <<'MD'
---
status: reviewed
---

```yaml
verification:
  automated:
    e2e:
      setup: { use_profile: true }
      scenarios:
        # - name: "scenario name"
        #   goal: "what success looks like"
  human_only:
    - "a check a person makes"
```
MD
e2e_is none "a commented-out sample scenario is not an entry"
assert_contains "$STAGE_OUT" "HUMAN_ONLY:present" "and the sibling human_only block is still read on its own"

write_task_raw "$repo" <<'MD'
---
status: reviewed
---

```yaml
verification:
  automated:
    lint: true
  human_only:
    - "a check"
```
MD
e2e_is absent "a task.md with no e2e key"

# A scenarios: key outside an e2e: block is somebody else's key.
write_task_raw "$repo" <<'MD'
---
status: reviewed
---

```yaml
load_test:
  scenarios:
    - name: "ramp"
```
MD
e2e_is absent "a scenarios key under another parent is not e2e"

# The block sequence at the key's own indentation — valid YAML, and the shape
# the first draft of human_only's parser missed.
write_task_raw "$repo" <<'MD'
---
status: reviewed
---

```yaml
verification:
  automated:
    e2e:
      scenarios:
      - name: "same indentation as the key"
```
MD
e2e_is present "a block sequence at the scenarios key's own indentation"

# The template itself: a freshly written task.md must not disclose a placeholder.
cp "$GANTRY_ROOT/skills/plan/templates/task.md" "$repo/task.md"
e2e_is none "the shipped task template reports none, not a placeholder scenario"

rm -f "$repo/task.md"
e2e_is absent "no task.md at all"

# --- QA: the verdict file -------------------------------------------------------

write_task "$repo" reviewed
qa_is absent "no qa.md"

printf '# QA\nbranch: feat/x\noutcome: exercised\n\n## Scenarios\n- submit the form: pass\n' > "$repo/qa.md"
qa_is exercised "an exercised qa.md"

printf '# QA\noutcome: "unrunnable"   # qa-env.sh exited 1\n' > "$repo/qa.md"
qa_is unrunnable "a quoted outcome with a trailing comment"

printf '# QA\n  outcome: no-agent\n' > "$repo/qa.md"
qa_is no-agent "an indented outcome line"

printf '# QA\noutcome: no-scenarios\n' > "$repo/qa.md"
qa_is no-scenarios "no-scenarios"

printf '# QA\nverdict: passed\n' > "$repo/qa.md"
qa_is unknown "a qa.md with no outcome line"

printf '# QA\noutcome: passed\n' > "$repo/qa.md"
qa_is unknown "an outcome outside the set"

# qa.md does not move the phase: the verdict is reported, never enforced.
assert_contains "$STAGE_OUT" "PHASE:ship" "a reviewed task with a qa.md still resolves to ship"

# --- QA_ROLE: and QA_ENV: the repo's opt-ins ------------------------------------

run_stage "$repo"
assert_contains "$STAGE_OUT" "QA_ROLE:absent" "no .claude/agents/qa.md is reported absent"
assert_contains "$STAGE_OUT" "QA_ENV:absent" "no .claude/qa-env.sh is reported absent"

mkdir -p "$repo/.claude/agents"
printf -- '---\nname: qa\ntools: Read, Bash\n---\nDrive the app.\n' > "$repo/.claude/agents/qa.md"
run_stage "$repo"
assert_contains "$STAGE_OUT" "QA_ROLE:present" "the repo's qa agent is reported"
assert_contains "$STAGE_OUT" "QA_ENV:absent" "without an env script beside it"

printf '#!/usr/bin/env bash\nexit 0\n' > "$repo/.claude/qa-env.sh"
run_stage "$repo"
assert_contains "$STAGE_OUT" "QA_ENV:present" "the env script is reported"

# --- the output contract --------------------------------------------------------

last="$(printf '%s\n' "$STAGE_OUT" | tail -n 1)"
case "$last" in
  PHASE:*) _pass "PHASE: is still the last line" ;;
  *)       _fail "PHASE: is no longer the last line — got: $last" ;;
esac

finish
