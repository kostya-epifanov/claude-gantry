#!/usr/bin/env bash
#
# detect_stage.sh's HUMAN_ONLY: line is the input to the fixed "Not proven by
# this run" heading gantry:ship puts in a pull request body. The heading exists
# so that its ABSENCE is information, which only holds if the line underneath it
# is a fact rather than a reading — hence these assertions rather than a prose
# rule asking a driver to look.
#
# The load-bearing cases here, as opposed to the thorough ones:
#
#   - "a block sequence at the key's own indentation" is valid YAML that the
#     first draft of the parser reported as `none`. None of the three human_only
#     blocks in this repo happens to use that shape, so no fixture built from
#     them would have caught it, and the failure is silent in the one direction
#     this must never fail in: a populated list read as empty means the
#     disclosure is dropped and nothing says so.
#
#   - "the last line is still PHASE:" is not about human_only at all. Every
#     other assertion here is a substring test over the whole of STAGE_OUT, so
#     all of them pass equally for a new line appended AFTER PHASE: — which
#     would break the output contract the script's own header promises.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

repo="$(mkrepo human_only)"

human_only_is() {  # human_only_is <expected> <label>; task.md must already be in place
  run_stage "$repo"
  assert_contains "$STAGE_OUT" "HUMAN_ONLY:$1" "$2 -> $1"
}

# --- the three states the disclosure routes on -------------------------------

write_task_raw "$repo" <<'MD'
---
status: planned
---

## How to verify

```yaml
verification:
  automated:
    lint: true
  human_only:
    - "the check a person has to make"
```
MD
human_only_is present "a populated list in the canonical fenced block"

write_task_raw "$repo" <<'MD'
---
status: planned
---

## How to verify

```yaml
verification:
  human_only:
```
MD
human_only_is none "the key with no entries under it"

write_task_raw "$repo" <<'MD'
---
status: planned
---

## How to verify

Nothing here mentions the block at all.
MD
human_only_is absent "a task.md with no such key"

rm -f "$repo/task.md"
human_only_is absent "no task.md at all"

# --- YAML shapes that must not read as empty ---------------------------------
# Every one of these is a populated list. Reporting `none` for any of them drops
# a disclosure silently, which is the whole failure this line exists to prevent.

write_task_raw "$repo" <<'MD'
---
status: planned
---

```yaml
verification:
  human_only:
  - "a block sequence may sit at its key's own indentation"
```
MD
human_only_is present "a block sequence at the key's own indentation"

write_task_raw "$repo" <<'MD'
---
status: planned
---

```yaml
verification:
  human_only: ["the flow form is still a list"]
```
MD
human_only_is present "the flow form on the key line"

write_task_raw "$repo" <<'MD'
---
status: planned
---

```yaml
verification:
  human_only:
    - "an entry may wrap across lines, and this repo's own
       task.md writes them exactly this way"
    - "a second entry after a continuation line"
```
MD
human_only_is present "multi-line quoted entries"

write_task_raw "$repo" <<'MD'
---
status: planned
---

## Context

Earlier prose that merely mentions human_only: in passing.

## How to verify

```yaml
verification:
  human_only:
    - "the real block, later in the file"
```
MD
human_only_is present "a prose mention before the real block — present wins"

write_task_raw "$repo" <<'MD'
---
status: planned
---

```yaml
verification:
  human_only:
    - "the block runs to the end of the file"
MD
human_only_is present "the block terminated by EOF, fence never closed"

# Bullets are the conventional shape, not the only valid one. The sibling
# `automated:` key in the task template is itself written as a mapping, so this
# is the shape a hand-written block is most likely to drift into.
write_task_raw "$repo" <<'MD'
---
status: planned
---

```yaml
verification:
  human_only:
    device_check: "a person must confirm the message reaches a real device"
```
MD
human_only_is present "a mapping under the key is still a populated block"

write_task_raw "$repo" <<'MD'
---
status: planned
---

```yaml
verification:
  human_only:
    ["a flow list on the line after the key"]
```
MD
human_only_is present "a flow list on the following line"

# --- shapes that must read as empty ------------------------------------------

write_task_raw "$repo" <<'MD'
---
status: planned
---

```yaml
verification:
  human_only: []
  automated:
    lint: true
```
MD
human_only_is none "an explicitly empty flow list"

write_task_raw "$repo" <<'MD'
---
status: planned
---

```yaml
verification:
  human_only:
  automated:
    - "this bullet belongs to the sibling key, not to human_only"
```
MD
human_only_is none "a sibling key at the same indentation ends the block"

write_task_raw "$repo" <<'MD'
---
status: planned
---

```yaml
verification:
  human_only:
    # - "a commented-out placeholder is not an entry"
```
MD
human_only_is none "a commented-out placeholder"

# `---` matches a bare-bullet test but is a horizontal rule. The case that
# matters is an empty key in frontmatter, where the closing fence would
# otherwise be read as the block's one entry.
write_task_raw "$repo" <<'MD'
---
status: planned
human_only:
---

# task
MD
human_only_is none "the frontmatter's closing --- is not an entry"

# --- the template must not put the heading on every pull request -------------
# The task template ships a human_only placeholder. If it were a live entry,
# every task.md written from the template would report `present` and every
# gantry pull request would carry the heading with placeholder prose beneath it
# — which destroys the property the heading exists for. The template comments
# the placeholder out for the same reason it fences the fork checkbox.

cp "$GANTRY_ROOT/skills/plan/templates/task.md" "$repo/task.md"
human_only_is none "a task.md freshly copied from the template"

cp "$GANTRY_ROOT/examples/task.md" "$repo/task.md"
human_only_is none "the worked example, which must match the template"

# --- the output contract -----------------------------------------------------

run_stage "$repo"
last_line="$(printf '%s\n' "$STAGE_OUT" | tail -1)"
assert_contains "$last_line" "PHASE:" "the last line printed is still PHASE:"

finish
