#!/usr/bin/env bash
#
# secret-scan.sh — the publish gate for this repo.
#
# gantry was extracted from a private repository that holds real hostnames,
# keys and device identifiers. Publishing a secret is the one failure in this
# project that cannot be undone: a force-push does not un-ring the bell once a
# public repo has been cloned or indexed. So this runs before every push, and
# again in CI forever.
#
# Exit 0 = clean. Exit 1 = something matched; read it, do not skip it.

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

fail=0
hit() { printf '\n!! %s\n' "$1"; fail=1; }

# Scan tracked files only — untracked scratch is not being published. The
# scanners themselves are excluded: they necessarily contain every pattern
# they look for, and a scanner that flags itself is a scanner nobody runs.
files() { git ls-files -z -- ':!scripts/secret-scan.sh' ':!scripts/verify.sh'; }

scan() { # scan <label> <extended-regex>
  local label="$1" re="$2" out
  out="$(files | xargs -0 grep -InE "$re" 2>/dev/null)"
  if [ -n "$out" ]; then hit "$label"; printf '%s\n' "$out" | head -40; fi
}

echo "== S2: pattern scan over tracked files =="

scan "public IPv4 address" \
  '\b(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3}\b'

scan "Tailscale / tailnet identifiers" \
  '\.ts\.net|tailnet|taildrop|tailscale'

scan "private-infrastructure vocabulary" \
  'homebase-setup|HOMEBASE_|projects\.d|homebase-approve|homebase-session|homebase-lanes'

scan "personal identifiers" \
  '0xke|/Users/[a-z0-9]|epifanov\.lab|@gmail'

scan "key material / fingerprints" \
  'BEGIN [A-Z ]*PRIVATE KEY|ssh-rsa |ssh-ed25519 |SHA256:[A-Za-z0-9+/]{20,}'

scan "credential tokens" \
  'sk-ant-|ghp_|gho_|github_pat_|AKIA[0-9A-Z]{16}|xox[baprs]-|dop_v1_|Bearer [A-Za-z0-9._-]{20,}'

scan "hosting / deployment specifics" \
  'digitalocean|droplet|ams3|s-2vcpu|ubuntu-24-04-x64'

scan "references to private documents" \
  'SECRETS\.local|RECOVERY\.md|ADD-DEVICE|CHEATSHEET|dev-setup\.sh|raw_specs|OPEN-QUESTIONS|SYSTEM\.md|Slice [0-9]'

# One documented exception: docs/ARCHITECTURE.md and skills/sync/SKILL.md name
# `gantry-profile` on purpose, as the reference implementation of an optional
# resolver anyone can substitute. Anything else matching the vocabulary rule
# above is a genuine leak.

echo
echo "== S3: file-class scan =="
bad="$(files | tr '\0' '\n' | grep -E '(^|/)(\.env($|\.)|.*\.pem$|.*\.key$|.*\.p12$|.*_rsa$|.*_ed25519$|id_[a-z]+$|authorized_keys$|known_hosts$|\.netrc$|.*\.local\.json$|\.DS_Store$)' || true)"
if [ -n "$bad" ]; then hit "file classes that must never be tracked"; printf '%s\n' "$bad"; fi

echo
echo "== S4: third-party scanner =="
if command -v gitleaks >/dev/null 2>&1; then
  gitleaks detect --source . --no-git --redact || hit "gitleaks reported findings"
else
  echo "   gitleaks not installed — skipped (not a substitute for S2 above)"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "secret-scan: CLEAN"
  echo
  echo "Reminder: greps catch strings, not disclosure by implication."
  echo "Before the first publish, read README.md, docs/METHOD.md, docs/ARCHITECTURE.md"
  echo "and hooks/readiness-gate.sh's header end to end, as a stranger would."
else
  echo "secret-scan: FINDINGS ABOVE — do not publish until each is resolved."
fi
exit "$fail"
