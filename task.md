---
id: 2026-09-03-v0.4.1-integration
title: Integrate PR #13 and PR #12 into master as 0.4.1
project: claude-gantry
branch: integration/v0.4.1-batch
mode: semi-auto           # semi-auto | auto | unattended — which mode is driving
status: shipped           # planning | planned | grilled | implementing | implemented |
                          # reviewed | shipped | blocked. The readiness hook arms on
                          # exactly `implementing` and ignores every other value.
---

## Context & goal

Two changes were planned, implemented, gated and shipped in parallel worktrees, each against its
own contract and each opening its own pull request against `master`:

| PR | Branch | What it does |
|---|---|---|
| #13 | `feat/v0.4.1` | `ship` reviews only when asked; `review` becomes a thin `/code-review` wrapper, read-only by default |
| #12 | `refactor/rename-grill-to-plan-grill` | `/gantry:grill` becomes `/gantry:plan-grill` |

Both are green on their own gate and on CI, and `git` reports both as mergeable — against `master`,
individually. That is not the same as being correct together. They overlap on nine files, and the
overlap is not incidental: both rewrite **the sentence that names the chain**. #12 renames a phase
in it, #13 changes how the phase after that one is invoked. Where the two edits land on the same
line `git` stops and asks; where they land on adjacent lines `git` merges silently and either
change can be lost without a conflict marker ever appearing.

The goal is one branch carrying both, resolved against each other rather than merely merged, and
released as **0.4.1**.

## Acceptance criteria

- [x] Both branches are merged, one merge commit each, with no side's work dropped.
- [x] Every conflict `git` reported is resolved by hand — no `-X ours`/`-X theirs` over a real
      disagreement.
- [x] The chain string in `skills/auto/references/orchestration.md` carries **both** changes:
      `plan-grill` from #12 and `review --fix` from #13.
- [x] `/gantry:grill` appears nowhere in the tree as a command, and `skills/grill/` does not exist —
      #12's rename survived #13's edits to the same files.
- [x] `--reviewed` appears nowhere in the tree, and `skills/ship/SKILL.md` carries no `/code-review`
      invocation — #13's removals survived #12's edits to the same files. Both are enforced by
      `scripts/verify.sh`, so a regression fails CI rather than being noticed in review.
- [x] The phase vocabulary #12 deliberately left alone is still intact after the second merge:
      `status: grilled`, `PHASE=grill` and `--phase grill` tally the same as on `master`.
- [x] `bash scripts/verify.sh` exits 0, which runs `bash tests/run.sh` and every other check CI runs.
- [x] `.claude-plugin/plugin.json` reads `0.4.1` and `CHANGELOG.md`'s top section is `## 0.4.1`,
      covering both changes — #12 wrote its entry under `## Unreleased`.
- [x] `handover.md` carries both branches' still-open deferrals and nothing this integration fixed.

## How to verify

```yaml
verification:
  automated:
    lint: true              # shellcheck, via scripts/verify.sh
    tests: true             # bash tests/run.sh
  human_only:
    - "Whether the resolved chain line in orchestration.md is the one both authors
       would have written, rather than the one that merges. Nothing executes it; the
       only check on it is reading it."
    - "Whether 0.4.1 is the right number for a release carrying two breaking changes.
       The version was #13's choice for its own breaking change and this integration
       kept it; semver before 1.0 permits it and the repo has no stated policy."
    - "Whether the manifest description edit — 'grill' to 'plan-grill' in the phase
       list — is wanted. It is the plugin's trigger surface, paid every session, and
       #12 did not touch the file."
    - "Whether the three findings this integration fixed belong in the merge or in
       #13's own branch. Each is drift visible only once both merges are in the tree,
       each is a separate revertable commit, and the five that were design decisions
       rather than drift went to handover.md instead."
```

## Out of scope

- **The two source pull requests.** They stay open until whoever reviews this one decides; this
  branch supersedes them.
- **The findings in `handover.md`.** They remain open on purpose. Fixing any of them here would put
  unreviewed work inside a merge.
- **The phase/status vocabulary.** #12 left `grill` as the internal token deliberately and this
  integration does not revisit that; the asymmetry between the command and the phase is #12's
  documented decision, not drift introduced here.
- **Verifying that either change works at runtime.** Nothing in this repo executes a `SKILL.md`,
  and the harness loads `skills/` from the installed plugin, not from this worktree. Every claim
  about behaviour rests on reading prose — as it did in both source runs.
- **The commit-trailer disagreement.** `CONTRIBUTING.md` forbids a `Co-Authored-By` trailer; part
  of the git log carries one. Both source branches followed the written rule and so does this one.

## Affected areas

- `skills/auto/references/orchestration.md` — the only real conflict. Both sides rewrote the chain
  line; the resolution takes `plan-grill` from one and `review --fix` from the other.
- `CHANGELOG.md` — #13 opened `## 0.4.1`, #12 wrote `## Unreleased`. Folded into one section.
- `task.md`, `plan.md` — each branch's own contract. Replaced by this integration's, as the 0.4.0
  integration did.
- `skills/auto/SKILL.md`, `skills/auto-unattended/SKILL.md`, `references/delegation.md`,
  `skills/implement/SKILL.md`, `README.md`, `docs/SKILLS.md`, `docs/ARCHITECTURE.md` — edited by
  both sides and merged clean. The silent-loss risk lives here, which is what the two sweeps in
  `scripts/verify.sh` and the token census are for.
- `.claude-plugin/plugin.json` — the manifest description listed `grill` among the phase skills.

## Open questions

None.
