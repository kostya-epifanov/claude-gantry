#!/usr/bin/env bash
# run_gates.sh — gantry's one hard gate. Its exit code IS the gate:
# non-zero blocks push and PR, and nothing the model decides can override it.
# Run with: bash run_gates.sh [--strict]   (from anywhere inside the target repo/worktree)
#
#   --strict  Treat "no gates detected" as a hard FAILURE (exit 3) instead of a
#             pass. /gantry:auto-unattended uses this: with no human
#             watching, pushing code that ran zero checks is exactly what to refuse.
#
# Resolution order:
#   1. If <repo>/.claude/gates.sh exists, run THAT and use its exit code. A repo
#      owns its gate — this is how it reproduces its real CI, and it beats any
#      heuristic here. run_gates.sh does nothing else in this case.
#   2. Otherwise auto-detect: run each check the repo declares (test, lint,
#      build / typecheck) for the ecosystems it finds — at the repo root AND in
#      each subproject a bounded scan turns up, because a monorepo keeps its
#      manifests in subdirs (app/pubspec.yaml, landing/package.json), not at root.
#      The first failing check exits non-zero.
#   3. If NOTHING is detectable, print a NO-GATES notice — exit 0 (lenient) or,
#      under --strict, exit 3. An absent gate can't block; the caller must surface it.
#
# stdout is a transcript; the exit code is the contract:
#   0 = green · 1+ = a check failed (red) · 2 = usage/environment · 3 = NO-GATES under --strict.
#
# COVERAGE REPORTING, AND WHAT IT IS NOT. A gate that runs and passes while
# reading none of the paths a change touches exits 0 exactly like one that
# proved something. So the transcript also names the directories checks actually
# ran in:
#
#   COVERAGE root=<root-relative dir> check=<label>   one per check that ran
#   COVERAGE undeclared check=.claude/gates.sh        the repo-owned path
#   == coverage roots=<list|UNDECLARED|NONE> heuristic=... ==   exactly one, always
#
# A root is the directory a check was RUN IN. It is not the set of files that
# check READ, and the difference is not small: a pytest suite rooted at bot/ may
# import from the repo root, and a check that ran at the root "covers" every
# path by this measure while possibly reading almost none of them. Treat the
# overlap as a heuristic in both directions — it is reported so a reader can see
# a gate that could not have failed, and it is deliberately NOT an exit code.
# Nothing here refuses anything; zero overlap still exits 0, under --strict too.
#
# A repo-owned .claude/gates.sh is opaque by design, so its coverage is reported
# as UNDECLARED. That is neither zero roots nor every root, and collapsing it to
# either would be a lie in a direction that matters.
#
# 2 AND 3 ARE RESERVED FOR THIS SCRIPT'S OWN CONDITIONS. Callers act on them
# differently from an ordinary red — exit 2 means "the gate could not run, a
# broken environment, don't spend a fix attempt on it", exit 3 means "nothing
# was checked". But a *check* can exit 2 or 3 on its own (pytest exits 2 on a
# collection error, eslint on a fatal config error, and a repo's own
# .claude/gates.sh may use any code it likes), and passing that through
# verbatim would make a genuinely red tree read as a broken environment — the
# one misclassification that stops the fix loop from ever fixing it. So a
# failing check's 2 or 3 is normalised to 1 on the way out, with the original
# code printed. Every other code passes through unchanged.
set -uo pipefail

normalize_rc() {  # normalize_rc <rc> — collapse a check's 2/3 onto 1 (see above)
  case "$1" in
    2|3) echo "== note: check exited $1; reported as 1 (2 and 3 are reserved by run_gates.sh) ==" >&2; echo 1 ;;
    *)   echo "$1" ;;
  esac
}

# --- coverage bookkeeping ----------------------------------------------------
# Declared before the first exit, because every exit path prints a summary and
# the script runs under `set -u`: a COV_DIR reached unset would abort the shell
# with status 1, reporting a green tree as red — the one thing this change must
# not do.
#
# Deliberately NOT an EXIT trap, which would give the every-path invariant for
# free: this script uses command substitution ($(js_pm), $(normalize_rc ...)),
# each a subshell that inherits the trap, so a trap would print duplicate
# summaries and capture one INSIDE a substitution, corrupting its value.
#
# `cov_roots` is a space-delimited string because bash 3.2 (macOS system bash)
# has no associative arrays. A directory whose name contains a space or a comma
# would corrupt it; no such directory occurs here, and a quoting scheme across
# the three consumers would cost more than the case is worth.
COV_DIR="."          # root-relative dir the check now running was run in
cov_roots=""         # space-delimited, distinct, in the order first seen
cov_undeclared=0     # 1 once a repo-owned gate has been run
cov_summary_done=0   # the summary is printed exactly once

cov_note() {  # cov_note <root-relative dir> — remember a root, once.
  case " $cov_roots " in *" $1 "*) return 0 ;; esac
  cov_roots="$cov_roots $1"
}

coverage_summary() {  # print the one summary line; safe to call more than once.
  [ "$cov_summary_done" -eq 1 ] && return 0
  cov_summary_done=1
  local roots
  if [ "$cov_undeclared" -eq 1 ]; then
    roots="UNDECLARED"
  elif [ -z "$cov_roots" ]; then
    roots="NONE"
  else
    roots="$(printf '%s' "${cov_roots# }" | tr ' ' ',')"
  fi
  # The caveat is a token on the line, not a pointer at this file's header: a
  # captured transcript is the primary consumer and never carries the header.
  echo "== coverage roots=$roots heuristic=dirs-checks-ran-in-not-files-they-read =="
}

die_env() {  # die_env <message> — an environment failure: summarise, then exit 2.
  echo "$1"
  coverage_summary
  exit 2
}

STRICT=0
for arg in "$@"; do
  case "$arg" in
    --strict) STRICT=1 ;;
    *) echo "run_gates: unknown argument: $arg" >&2; coverage_summary; exit 2 ;;
  esac
done

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die_env "run_gates: not in a git repo"
cd "$ROOT" || die_env "run_gates: cannot enter $ROOT"

# --- 1. Repo-owned gate wins -------------------------------------------------
if [ -f "$ROOT/.claude/gates.sh" ]; then
  echo "== gate: .claude/gates.sh (repo-owned) =="
  # A repo-owned gate is opaque: it may run anything, anywhere. The only honest
  # report is that it did not declare its coverage.
  cov_undeclared=1
  echo "COVERAGE undeclared check=.claude/gates.sh"
  bash "$ROOT/.claude/gates.sh"
  rc=$?
  echo "== .claude/gates.sh exit $rc =="
  coverage_summary
  exit "$(normalize_rc "$rc")"
fi

# --- 2. Auto-detect ----------------------------------------------------------
# Each detected check runs; the first non-zero exit fails the whole gate.
# Ordered cheap-to-expensive so a fast lint failure short-circuits the build.
ran=0
fail=0

run() {  # run <label> <cmd...> — mutates the globals `ran`, `fail` and `cov_roots`.
  local label="$1"; shift
  echo "== gate: $label =="
  # Emitted before the check runs, so a transcript cut short still shows what
  # had been covered.
  echo "COVERAGE root=$COV_DIR check=$label"
  cov_note "$COV_DIR"
  echo "+ $*"
  "$@"
  local rc=$?
  echo "== $label exit $rc =="
  ran=$((ran + 1))
  [ $rc -ne 0 ] && fail=$rc
  return 0
}

has() { command -v "$1" >/dev/null 2>&1; }

# Pick the JS package manager by lockfile, falling back to npm.
js_pm() {
  if [ -f pnpm-lock.yaml ] && has pnpm; then echo "pnpm";
  elif [ -f yarn.lock ] && has yarn; then echo "yarn";
  elif has npm; then echo "npm";
  else echo ""; fi
}

# Does package.json (in the current dir) declare a script named "$1"?
# Must not depend on `node`: a standalone-pnpm or bun repo has package.json but
# may have no `node` on PATH, and a node-only probe would silently skip every JS
# gate (a false green — the worst outcome for a gate). Layer parsers by accuracy.
has_npm_script() {
  [ -f package.json ] || return 1
  if has node; then
    node -e "process.exit(((require('./package.json').scripts)||{})['$1']?0:1)" 2>/dev/null
  elif has jq; then
    jq -e --arg s "$1" '.scripts[$s] // empty' package.json >/dev/null 2>&1
  else
    # No JSON parser: scoped grep for a top-level "<name>": key. The closing quote
    # keeps "lint" from matching "lint-staged"; may over-match a same-named key in
    # another object, but a spurious run beats skipping the gate entirely.
    grep -qE "\"$1\"[[:space:]]*:" package.json
  fi
}

# Run every ecosystem check present in directory $1, labelling with prefix $2.
# Operates in that dir (checks read relative manifests) and returns to $ROOT.
# Mutates `ran`/`fail`; bails on the first failure so a red short-circuits the rest.
gates_in_dir() {
  local dir="$1" px="$2"
  # The coverage root for every check below: "." at the repo root, root-relative
  # otherwise — the same shape as the label prefix $px.
  if [ "$dir" = "$ROOT" ]; then COV_DIR="."; else COV_DIR="${dir#"$ROOT"/}"; fi
  cd "$dir" || { cd "$ROOT" || die_env "run_gates: cannot return to $ROOT"; return 0; }

  # JavaScript / TypeScript
  if [ -f package.json ]; then
    local pm; pm="$(js_pm)"
    if [ -n "$pm" ]; then
      local runner=(); case "$pm" in npm) runner=(npm run);; yarn) runner=(yarn);; pnpm) runner=(pnpm run);; esac
      local s
      for s in lint typecheck build test; do
        if has_npm_script "$s"; then run "${px}js:$s" "${runner[@]}" "$s"; [ $fail -ne 0 ] && break; fi
      done
    fi
  fi

  # Dart / Flutter — analyze + test; no build step (slow, needs a device/target).
  # A Flutter package pins the flutter SDK under dependencies (`  flutter:`); a
  # plain Dart package doesn't. Prefer the matching toolchain; skip if absent.
  if [ $fail -eq 0 ] && [ -f pubspec.yaml ]; then
    if grep -qE '^[[:space:]]*flutter[[:space:]]*:' pubspec.yaml && has flutter; then
      run "${px}flutter:analyze" flutter analyze
      [ $fail -eq 0 ] && run "${px}flutter:test" flutter test
    elif has dart; then
      run "${px}dart:analyze" dart analyze
      [ $fail -eq 0 ] && run "${px}dart:test" dart test
    fi
  fi

  # Python
  if [ $fail -eq 0 ] && { [ -f pyproject.toml ] || [ -f setup.cfg ] || [ -f tox.ini ] || [ -f setup.py ]; }; then
    if has ruff; then run "${px}py:ruff" ruff check .; fi
    if [ $fail -eq 0 ] && has pytest; then run "${px}py:pytest" pytest -q; fi
  fi

  # Rust
  if [ $fail -eq 0 ] && [ -f Cargo.toml ] && has cargo; then
    run "${px}rust:test" cargo test --quiet
  fi

  # Go
  if [ $fail -eq 0 ] && [ -f go.mod ] && has go; then
    run "${px}go:vet" go vet ./...
    [ $fail -eq 0 ] && run "${px}go:test" go test ./...
  fi

  cd "$ROOT" || die_env "run_gates: cannot return to $ROOT"
}

# Root first, then each subproject a bounded scan finds (monorepo support).
# Trade-off: in a JS-workspaces monorepo whose root `test` already fans out to
# members, the scan re-runs each member's `test` too — redundant work, not a wrong
# result. That's deliberate: for a gate, running a check twice is safe, but skipping
# a real subproject (a false green) is the exact failure this scan exists to prevent.
gates_in_dir "$ROOT" ""

if [ $fail -eq 0 ]; then
  seen=" $ROOT "
  while IFS= read -r manifest; do
    [ -n "$manifest" ] || continue
    d="$(cd "$(dirname "$manifest")" && pwd)"
    case "$seen" in *" $d "*) continue ;; esac   # a dir may hold several manifests
    seen="$seen$d "
    gates_in_dir "$d" "${d#"$ROOT"/}:"
    [ $fail -ne 0 ] && break
  done < <(find "$ROOT" -maxdepth 3 \
      \( -name node_modules -o -name vendor -o -name .git -o -name build \
         -o -name .dart_tool -o -name Pods -o -name .venv -o -name dist \) -prune -o \
      -type f \( -name package.json -o -name pubspec.yaml -o -name pyproject.toml \
         -o -name setup.py -o -name Cargo.toml -o -name go.mod \) -print 2>/dev/null | sort)
fi

# A Makefile 'test' target at the root, only if nothing above matched anywhere.
if [ $fail -eq 0 ] && [ $ran -eq 0 ] && [ -f Makefile ] && has make && grep -qE '^test:' Makefile; then
  # This run() is the one call outside gates_in_dir, so COV_DIR still holds
  # whichever subproject the scan visited last. Reset it, or a root check gets
  # labelled with a directory it never ran in.
  COV_DIR="."
  run "make:test" make test
fi

if [ $ran -eq 0 ]; then
  echo "== NO-GATES: no test/lint/build detected under $ROOT =="
  echo "   Add .claude/gates.sh to enforce this repo's checks."
  if [ "$STRICT" -eq 1 ]; then
    echo "   --strict: refusing to pass with zero enforced checks."
    coverage_summary
    exit 3
  fi
  coverage_summary
  exit 0
fi

coverage_summary
echo "== gates ran=$ran result=$([ $fail -eq 0 ] && echo GREEN || echo RED) =="
exit "$(normalize_rc "$fail")"
