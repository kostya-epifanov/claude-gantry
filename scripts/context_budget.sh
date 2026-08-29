#!/usr/bin/env bash
#
# context_budget.sh — the always-on context cost, as an exit code.
#
# WHY THIS EXISTS. A plugin's skill and agent `description:` fields are loaded
# into EVERY session, whether or not anything fires. That cost is invisible
# while you are writing a skill and permanent once you ship it, so it drifts
# upward one helpful clause at a time. gantry's own argument is that a
# guarantee belongs in a script's exit code rather than in a paragraph
# (docs/METHOD.md); this applies that to the one number the README quotes most.
#
# WHAT IT MEASURES, AND WHAT IT DOES NOT. This counts characters of frontmatter
# `description:` text. It is a PROXY for the token figure, not the figure
# itself. The authority is:
#
#     claude --plugin-dir . plugin details gantry
#
# which prints the real projected always-on cost. That command cannot be the
# enforced check: scripts/verify.sh already treats the `claude` CLI as optional
# because CI runners do not have it, and a budget that silently skips is not a
# budget. So the enforced check is the proxy, the authority is the CLI, and the
# two are reconciled by hand whenever CEILING moves — the commit that changes
# it should quote a fresh reading.
#
# Exit 0 = within budget. Exit 1 = over. Exit 2 = could not run.

set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

# The ceiling, in characters of description text.
#
# Set from the v0.3.0 measurement: 5,670 characters across 15 components, which
# the CLI projects at ~1,464 always-on tokens — call it ~3.9 characters per
# token — plus about 10% of headroom.
#
# Headroom is deliberate. Too tight and the check blocks a legitimate skill
# whose description genuinely needs the words; too loose and it never fires.
# Raising it is a normal thing to do, and it should be a visible line in a diff
# with a re-measured token count beside it. That visibility is the whole point:
# the cost does not grow by decision, it grows by one helpful clause at a time.
CEILING=6250

# Extract the value of a single-line `description:` field from a frontmatter
# block. Every skill and agent in this repo uses the one-line form, and
# verify.sh's frontmatter checks would catch one that did not.
description_chars() {
  sed -n 's/^description:[[:space:]]*//p' "$1" | head -1 | wc -c | tr -d ' '
}

total=0
count=0

for f in skills/*/SKILL.md agents/*.md; do
  [ -f "$f" ] || continue
  n="$(description_chars "$f")"
  if [ -z "$n" ] || [ "$n" -le 1 ]; then
    printf 'context_budget: %s has no single-line description: field\n' "$f" >&2
    exit 2
  fi
  total=$((total + n))
  count=$((count + 1))
  printf '  %6s  %s\n' "$n" "$f"
done

if [ "$count" -eq 0 ]; then
  echo "context_budget: found no skills or agents to measure" >&2
  exit 2
fi

printf '\n  %6s  total across %s components (ceiling %s)\n' "$total" "$count" "$CEILING"

if [ "$total" -gt "$CEILING" ]; then
  cat >&2 <<EOF

context_budget: OVER BUDGET — $total characters of description, ceiling $CEILING.

Every character here is paid in every session, by every user, whether or not
anything fires. Either tighten the descriptions, or raise CEILING in this file
deliberately — and if you raise it, re-measure and update the figures in
README.md and docs/SKILLS.md in the same commit:

    claude --plugin-dir . plugin details gantry
EOF
  exit 1
fi

echo "context_budget: within budget"
exit 0
