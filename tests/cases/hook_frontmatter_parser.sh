#!/usr/bin/env bash
#
# The frontmatter parser decides whether the gate arms, so every tolerance it
# claims is a security-relevant claim: a status the parser fails to read is a
# gate that silently never fires.
#
# The same function is duplicated byte-for-byte into lib/detect_stage.sh, and
# scripts/verify.sh diffs the two copies — so these cases cover both, and that
# existing drift check is what keeps them covering both.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

# --- forms that MUST be read as implementing (red gate => rc 2) --------------
ok="$(mkrepo parser_accepts)"
write_gates "$ok" 1

printf '\xef\xbb\xbf---\nstatus: implementing\n---\n\n# task\n' | write_task_raw "$ok"
run_hook "$ok"
assert_rc 2 "$HOOK_RC" "a UTF-8 BOM before the fence still arms"

printf -- '---\r\nstatus: implementing\r\n---\r\n\r\n# task\r\n' | write_task_raw "$ok"
run_hook "$ok"
assert_rc 2 "$HOOK_RC" "a CRLF file still arms"

printf -- '---\nstatus: "implementing"\n---\n' | write_task_raw "$ok"
run_hook "$ok"
assert_rc 2 "$HOOK_RC" "a double-quoted value still arms"

printf -- "---\nstatus: 'implementing'\n---\n" | write_task_raw "$ok"
run_hook "$ok"
assert_rc 2 "$HOOK_RC" "a single-quoted value still arms"

printf -- '---\nstatus: implementing # still going\n---\n' | write_task_raw "$ok"
run_hook "$ok"
assert_rc 2 "$HOOK_RC" "a trailing # comment is stripped"

printf -- '\n\n---\nstatus: implementing\n---\n' | write_task_raw "$ok"
run_hook "$ok"
assert_rc 2 "$HOOK_RC" "leading blank lines before the fence still arm"

printf -- '---\nid: x\ntitle: y\nstatus: implementing\nmode: auto\n---\n' \
  | write_task_raw "$ok"
run_hook "$ok"
assert_rc 2 "$HOOK_RC" "status among other frontmatter keys still arms"

# --- forms that MUST NOT be read as a status (=> inert, rc 0) ----------------
no="$(mkrepo parser_rejects)"
write_gates "$no" 1

# An unterminated fence must not fall through into scanning the body. Reading
# a body line as frontmatter would arm the gate off prose.
printf -- '---\nstatus: implementing\n\n# task, and the fence never closed\n' \
  | write_task_raw "$no"
run_hook "$no"
assert_rc 0 "$HOOK_RC" "an unterminated frontmatter fence yields no status"

printf -- '# just a heading\n\nstatus: implementing\n' | write_task_raw "$no"
run_hook "$no"
assert_rc 0 "$HOOK_RC" "a file with no frontmatter block at all yields no status"

printf -- '---\nid: x\n---\n\nstatus: implementing\n' | write_task_raw "$no"
run_hook "$no"
assert_rc 0 "$HOOK_RC" "a status line in the body is not frontmatter"

printf -- '---\nstatus: implementing-ish\n---\n' | write_task_raw "$no"
run_hook "$no"
assert_rc 0 "$HOOK_RC" "a status that merely starts with the value does not arm"

assert_gate_not_run "$no" "no rejected form ever ran the gate"

finish
