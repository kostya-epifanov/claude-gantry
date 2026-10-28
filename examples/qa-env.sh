#!/usr/bin/env bash
#
# .claude/qa-env.sh — copy this to your repo root as .claude/qa-env.sh.
#
# When this file exists beside .claude/agents/qa.md, /gantry:qa runs it before
# dispatching the agent, and its exit code decides whether the agent is
# dispatched at all. It is the deterministic half of a QA pass — build the app,
# boot the device or server, install, log in as the test user — the half that
# is brittle when a model does it by hand and boring when a script does.
#
# THE CONTRACT (this is all gantry cares about):
#   exit 0     the app is up and reachable — the qa agent is dispatched
#   exit 1+    setup failed (build broke, device missing, login failed) —
#              reported as QA:unrunnable; the chain continues
#   exit 2     reserved for "the script could not run" (bad env, missing tool) —
#              also unrunnable, reported as such
#
# `unrunnable` is never a failed QA. "The feature does not work" and "nobody
# could check whether it works" are different lines in the PR body, and this
# exit code is what keeps them apart — so exit non-zero honestly rather than
# exit 0 over a device you are not sure booted.
#
# ARGUMENT. $1 is the evidence directory for this task
# (.claude/artifacts/qa/<task-id>/, already excluded from git). Drop build and
# boot logs there so a failure can be read after the fact. You may ignore it.
#
# THE TEST PROFILE. task.md's e2e block says `setup: { use_profile: true }`.
# This script is where that is honoured: seed the account, pick the flavour,
# point the app at the staging backend. gantry passes nothing else.
#
# Two rules worth internalising:
#   1. Wait for readiness, not for the launch command to return. An emulator
#      that "started" is not an emulator that is booted; a dev server that
#      printed its banner may not be serving yet. Poll for the thing the agent
#      will actually touch.
#   2. Be idempotent. The phase re-runs this after a --fix, and a human runs it
#      by hand while writing the agent. A second run must not fail because the
#      first one left an emulator up.

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

EVIDENCE="${1:-.claude/artifacts/qa/local}"
mkdir -p "$EVIDENCE" || exit 2

step() { printf '\n==> %s\n' "$*"; }

# --- replace everything below with your stack's real setup -------------------

# Flutter + Android emulator + Maestro
# step "build";   flutter build apk --debug --flavor staging >"$EVIDENCE/build.log" 2>&1 || exit 1
# step "boot";    emulator -avd qa -no-window -no-audio >"$EVIDENCE/emulator.log" 2>&1 &
#                 adb wait-for-device || exit 1
#                 until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do sleep 2; done
# step "install"; adb install -r build/app/outputs/flutter-apk/app-staging-debug.apk >>"$EVIDENCE/build.log" 2>&1 || exit 1
# step "profile"; adb shell am start -n com.example.app/.MainActivity --es qa_user "$QA_TEST_USER" || exit 1

# Web + Playwright MCP
# step "build";   npm run build >"$EVIDENCE/build.log" 2>&1 || exit 1
# step "serve";   npm run preview -- --port 4173 >"$EVIDENCE/server.log" 2>&1 &
# step "ready";   for _ in $(seq 1 30); do curl -fsS http://localhost:4173/ >/dev/null && break; sleep 1; done
#                 curl -fsS http://localhost:4173/ >/dev/null || exit 1
# step "profile"; curl -fsS -X POST http://localhost:4173/__qa/seed -d "user=$QA_TEST_USER" >/dev/null || exit 1

# iOS simulator
# step "build";   xcodebuild -scheme App -destination 'platform=iOS Simulator,name=iPhone 15' build >"$EVIDENCE/build.log" 2>&1 || exit 1
# step "boot";    xcrun simctl boot 'iPhone 15' 2>/dev/null; xcrun simctl bootstatus 'iPhone 15' -b || exit 1
# step "install"; xcrun simctl install booted "$(find ~/Library/Developer/Xcode/DerivedData -name App.app | head -1)" || exit 1

# --- an environment you did not configure is not up -------------------------
# Delete this once you have real steps above.
printf '\n==> no environment configured in .claude/qa-env.sh\n' >&2
exit 2

exit 0
