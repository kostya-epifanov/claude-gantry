#!/usr/bin/env bash
#
# --fast is a request, handed to a repo-owned .claude/gates.sh as
# GANTRY_GATE_MODE=fast. What it narrows to is the repo's business; what this
# case pins is the handoff and its two guards:
#
#   - The variable comes from the flag ONLY. A detached run's environment may
#     already carry GANTRY_GATE_MODE=fast, and the readiness hook and integrate
#     call run_gates.sh without --fast because they must run the full suite. An
#     inherited value that leaked through would quietly narrow both.
#   - Nothing about the exit-code contract moves. A red repo gate is still red
#     under --fast, NO-GATES is still exit 3 under --strict --fast, and the
#     timing line prints on the exit-2 paths without tripping `set -u` — a
#     usage error that read as exit 1 would burn a fix attempt.

TESTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=tests/lib.sh
. "$TESTS_DIR/lib.sh"

mode_gate() {  # mode_gate <repo> <exit> — a repo gate that reports the mode it was handed
  write_gates_body "$1" <<EOF
#!/usr/bin/env bash
echo "mode-seen=\${GANTRY_GATE_MODE:-unset}"
exit $2
EOF
}

# --- default is full, and says so -------------------------------------------
repo="$(mkrepo fast_default)"
mode_gate "$repo" 0
run_gate "$repo"
assert_rc 0 "$GATE_RC" "a green repo gate is green without --fast"
assert_contains "$GATE_OUT" "mode-seen=full" "without --fast the repo gate is handed full"
assert_contains "$GATE_OUT" "== gate mode=full requested=full seconds=" "the timing line names the full mode"

# --- --fast hands fast down -------------------------------------------------
run_gate "$repo" --fast
assert_rc 0 "$GATE_RC" "--fast keeps a green gate green"
assert_contains "$GATE_OUT" "mode-seen=fast" "--fast hands GANTRY_GATE_MODE=fast to the repo gate"
assert_contains "$GATE_OUT" "== gate mode=fast requested=fast seconds=" "the timing line names the fast mode"

if printf '%s\n' "$GATE_OUT" | grep -qE '^== gate mode=fast requested=fast seconds=[0-9]+ ==$'; then
  _pass "seconds is a bare integer the journal can carry"
else
  _fail "seconds is a bare integer the journal can carry"
fi

# --- both flag orders combine with --strict ---------------------------------
run_gate "$repo" --strict --fast
assert_rc 0 "$GATE_RC" "--strict --fast is accepted"
assert_contains "$GATE_OUT" "mode-seen=fast" "and hands fast down"
run_gate "$repo" --fast --strict
assert_rc 0 "$GATE_RC" "--fast --strict is accepted"
assert_contains "$GATE_OUT" "mode-seen=fast" "in either order"

# --- an inherited variable does not leak ------------------------------------
GATE_OUT="$(cd "$repo" && GANTRY_GATE_MODE=fast bash "$RUN_GATES" 2>&1)"; GATE_RC=$?
assert_rc 0 "$GATE_RC" "an inherited GANTRY_GATE_MODE does not break the gate"
assert_contains "$GATE_OUT" "mode-seen=full" "an inherited GANTRY_GATE_MODE=fast is overridden: no flag, full"

# The hook is the caller this guard exists for: it must run the full suite even
# when the session that stops carries the variable.
hooked="$(mkrepo fast_hook)"
mode_gate "$hooked" 0
write_task "$hooked" implementing
GANTRY_GATE_MODE=fast run_hook "$hooked"
assert_rc 0 "$HOOK_RC" "the hook passes a green gate with the variable in its env"
if grep -q "mode-seen=full" "$hooked"/.claude/artifacts/gate-[0-9]*.log 2>/dev/null; then
  _pass "the readiness hook hands its gate full, whatever the environment says"
else
  _fail "the readiness hook hands its gate full, whatever the environment says"
fi

# --- red stays red ----------------------------------------------------------
red="$(mkrepo fast_red)"
mode_gate "$red" 1
run_gate "$red" --strict --fast
assert_rc 1 "$GATE_RC" "a red repo gate is red under --fast"
assert_contains "$GATE_OUT" "== gate mode=fast requested=fast seconds=" "the timing line prints on a red gate too"

# --- auto-detect has nothing to narrow --------------------------------------
stub_cmd npm 0
auto="$(mkrepo fast_autodetect)"
printf '{\n  "name": "x",\n  "scripts": { "test": "exit 0" }\n}\n' >"$auto/package.json"
run_gate "$auto" --fast
assert_rc 0 "$GATE_RC" "auto-detect under --fast still runs and passes"
assert_contains "$GATE_OUT" "js:test" "the full detected suite ran"
assert_contains "$GATE_OUT" "== gate mode=full requested=fast seconds=" "and the timing line says fast was asked for, full ran"
if [ "$(printf '%s\n' "$GATE_OUT" | grep -c '^== gate mode=')" -eq 1 ]; then
  _pass "exactly one line starts '== gate mode=' — nothing for a reader to copy the wrong mode from"
else
  _fail "exactly one line starts '== gate mode=' — nothing for a reader to copy the wrong mode from"
fi

# An auto-detected check is handed full too, even when the environment says fast:
# the npm stub reports the variable it sees.
# shellcheck disable=SC2016  # the $ is for the stub, not this shell
printf '#!/usr/bin/env bash\necho "mode-seen=${GANTRY_GATE_MODE:-unset}"\nexit 0\n' >"$CASE_TMP/bin/npm"
GATE_OUT="$(cd "$auto" && GANTRY_GATE_MODE=fast bash "$RUN_GATES" 2>&1)"; GATE_RC=$?
assert_rc 0 "$GATE_RC" "auto-detect with an inherited GANTRY_GATE_MODE passes"
assert_contains "$GATE_OUT" "mode-seen=full" "an auto-detected check sees full, not the inherited fast"

# --- NO-GATES and usage errors keep their codes -----------------------------
none="$(mkrepo fast_nothing)"
run_gate "$none" --strict --fast
assert_rc 3 "$GATE_RC" "NO-GATES under --strict --fast is still exit 3"
assert_contains "$GATE_OUT" "== gate mode=full requested=fast seconds=" "the timing line prints on the NO-GATES exit"

run_gate "$repo" --fast --bogus
assert_rc 2 "$GATE_RC" "an unknown argument beside --fast is still exit 2"
assert_contains "$GATE_OUT" "== gate mode=full requested=fast seconds=" "the timing line prints on the usage exit without tripping set -u"
run_gate "$repo" --bogus --fast
assert_rc 2 "$GATE_RC" "an unknown argument before --fast is still exit 2"
assert_contains "$GATE_OUT" "== gate mode=full requested=fast seconds=" "requested= does not depend on argument order"

plain="$(mkdir_plain fast_not_a_repo)"
run_gate "$plain" --fast
assert_rc 2 "$GATE_RC" "outside a repo --fast is still exit 2"
if printf '%s\n' "$GATE_OUT" | grep -qE '^== gate mode=full requested=fast seconds=[0-9]+ ==$'; then
  _pass "the full timing line prints on the not-a-repo exit"
else
  _fail "the full timing line prints on the not-a-repo exit"
fi

finish
