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
# the CLI then projected at ~1,464 always-on tokens — ~3.9 characters per token
# — plus about 10% of headroom.
#
# The CLI's estimator has since changed, so the ratio has too. Re-measured at
# v0.5.1: the v0.3.0 tree now projects at ~1,927 tokens, and the v0.5.1 tree
# (5,965 characters) at ~2,024 — ~2.95 characters per token, putting this
# ceiling near ~2,120 tokens with about 5% headroom left. The ceiling itself
# is unchanged; only the token figure it stands for moved.
#
# Headroom is deliberate. Too tight and the check blocks a legitimate skill
# whose description genuinely needs the words; too loose and it never fires.
# Raising it is a normal thing to do, and it should be a visible line in a diff
# with a re-measured token count beside it. That visibility is the whole point:
# the cost does not grow by decision, it grows by one helpful clause at a time.
#
# Raised from 6,250 to 6,600 characters when `integrate` was added. Fresh reading
# of this tree, for the token figure the docs quote:
#
#     claude --plugin-dir . plugin details gantry
#     Always-on: ~2,124 tok   (integrate ~100 of it)
#
# The raise is in CHARACTERS, which is what this file measures; the reading above
# is in tokens and is not what the ceiling is derived from. Thirteen skills and
# three agents came to exactly 6,250 characters — zero headroom, so the next
# clause anywhere would have failed the gate, and the obvious fix would then be
# to trim whichever description was easiest rather than whichever was least
# useful. 6,600 was that measured 6,250 plus about 5%: a deliberately thinner
# margin than the ~10% v0.3 started with, because the text is now four times
# closer to the ceiling and each raise should be a visible line in a diff rather
# than a comfortable cushion.
#
# Raised from 6,600 to 6,950 for 0.7.0, where `plan-grill` became two skills:
# `plan-critique` (headless) and `grill` (the conversation). This one is worth
# spelling out, because it is the case the whole file is designed to catch.
#
# The split alone was nearly free — one 338-character description out, two in at
# 340 and 339, which landed at 6,591 against the old ceiling with nine characters
# to spare. What actually broke the budget was second-order: BOTH driver
# descriptions name the chain in prose, so one command name becoming two grew
# `auto` from 531 to 554 as well. That is the drift this ceiling exists to make
# visible — nobody set out to spend it, and a per-skill reading would not have
# shown it.
#
# Measured on this tree, not estimated:
#
#     bash scripts/context_budget.sh      -> 6,612 characters, 17 components
#     claude --plugin-dir . plugin details gantry
#       Always-on: ~2,230 tok   (plan-critique ~120, grill ~110 of it)
#
# ~2.97 characters per token here, so 6,950 stands for roughly ~2,340 tokens. The
# raise is 6,612 plus about 5%, the same thin margin as the last one and for the
# same reason.
#
# Raised again, from 6,950 to 7,600, when `qa` joined the same 0.7.0 tree. On its
# own branch (before the plan-grill split) qa measured 6,809 against a 7,150
# ceiling: its description is 551 characters, and the other eight were
# second-order — both driver descriptions and the manifest name the chain in
# prose, so one new phase grew each by four. Combined with the split, measured
# on this tree:
#
#     bash scripts/context_budget.sh      -> 7,227 characters, 18 components
#     (with #33's longer prune-worktrees description; 7,171 before it)
#     claude --plugin-dir . plugin details gantry
#       Always-on: ~2,456 tok
#
# 7,600 is that plus about 5%, the same thin margin as the last raises and for
# the same reason.
CEILING=7600

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
