---
id: 2026-08-31-v0.4-integration
title: Integrate the six parallel lanes into 0.4.0, resolving what they disagreed about
project: claude-gantry
branch: integration/v0.4-batch
mode: semi-auto           # semi-auto | auto | unattended — which mode is driving
status: shipped           # planning | planned | grilled | implementing | implemented |
                          # reviewed | shipped | blocked. The readiness hook arms on
                          # exactly `implementing` and ignores every other value.
---

## Context & goal

Six changes were planned, implemented, gated and shipped in parallel worktrees, one per lane, each
against its own contract and each opening its own draft pull request:

| Lane | Branch | PR | Tickets |
|---|---|---|---|
| A | `fix/journal-append-helper` | #10 | GANTRY-4, GANTRY-7 |
| B | `fix/detector-inherited-task-and-plan-order` | #9 | GANTRY-5, GANTRY-9, GANTRY-13 |
| C | `fix/verify-sees-untracked-files` | #7 | GANTRY-6 |
| D | `feat/gate-coverage-report` | #6 | GANTRY-8 |
| E | `feat/ship-discloses-what-was-not-proven` | #8 | GANTRY-11, GANTRY-12, GANTRY-14 |
| F | `fix/agent-env-claims-cite-source` | #5 | GANTRY-10 |

All six are green on their own gate and on CI. That is not the same as being green together, and
this task is the difference. Two lanes wrote into the journal a shape a third had just made
impossible, and both merged clean because neither touched the other's file: lane D documented a
`coverage` object on the `gate` event, lane E documented a whole new `disclosure` event, and lane A
— landing separately — replaced the hand-built `jq` idiom with `lib/journal_append.sh`, which
validates the events and fields it will write and refuses anything else. `git` had nothing to
complain about. The result would have been a release whose own documentation instructed the driver
to run a command the release refuses.

The goal is one branch that carries all six, resolved against each other rather than merely merged,
and released as **0.4.0**.

## Acceptance criteria

- [x] All six lane branches are merged, one merge commit each, with no lane's work dropped.
- [x] Every conflict `git` reported is resolved by hand — no `-X ours`/`-X theirs` over a real
      disagreement.
- [x] `lib/detect_stage.sh` carries both lanes' additions: `TASK:inherited` and the `HOOK:` rename
      from B, `HUMAN_ONLY:` from E, and the detector runs and prints all of them.
- [x] `lib/journal_append.sh` accepts every journal line this release's own documentation tells a
      driver to write, including D's `coverage` object and E's `disclosure` event.
- [x] Every `journal_append.sh` invocation documented under `skills/auto-unattended/` is *executed*
      by `tests/cases/journal_append.sh`, not merely scanned.
- [x] `bash scripts/verify.sh` exits 0, which runs `bash tests/run.sh` and every other check CI runs.
- [x] `.claude-plugin/plugin.json` reads `0.4.0` and `CHANGELOG.md`'s top section is `## 0.4.0`,
      covering all six lanes — including the two that wrote no changelog entry of their own.
- [x] `handover.md` carries every finding the six lanes deferred and still open, and nothing that
      this integration went on to fix.

## How to verify

```yaml
verification:
  automated:
    lint: true              # shellcheck, via scripts/verify.sh
    tests: true             # bash tests/run.sh, 15 cases
  human_only:
    - "Whether resolving lane B's HOOK: prose against lane D's coverage prose in
       skills/implement/SKILL.md kept both claims intact, rather than producing a
       paragraph that reads well and says less than either lane meant."
    - "Whether the two fixes this integration made beyond conflict resolution —
       verify.sh's mktemp guard and gantry-explorer's markdown citations — belong in
       this pull request or in their own. Both are recorded as deliberate integrator
       decisions and both are single, revertable commits."
```

## Out of scope

- **Merging the six lane pull requests.** They stay open. This branch is a seventh pull request
  that supersedes them; closing them is a decision for whoever reviews this one.
- **The board.** No Notion ticket is moved, closed, or filed by this change.
- **The findings in `handover.md`.** Nine remain open on purpose, including the three lane B named
  as the unclosed half of GANTRY-5. Fixing any of them here would put unreviewed work inside a
  merge.
- **Retro-fitting lane D's `--strict` refusal**, which its own contract excluded.
- **The commit-trailer disagreement.** `CONTRIBUTING.md` forbids a `Co-Authored-By` trailer and the
  last twenty commits carry one. All six lanes followed the written rule and so does this branch;
  which of the two is wrong is a separate decision.

## Affected areas

- `lib/detect_stage.sh` — the only source file both B and E rewrote. Their additions are
  independent (`task_is_inherited()` / `human_only_state()`) and both edit the output block.
- `lib/journal_append.sh` — where D's and E's journal shapes meet A's validator. Gains four
  `--coverage-*` flags and the `disclosure` event.
- `scripts/verify.sh` — C's enumeration change, plus the `mktemp -d` guard three lanes recorded and
  none owned.
- `agents/gantry-explorer.md`, `skills/plan/SKILL.md` — the producer C's change turned into a local
  gate failure.
- `skills/implement/SKILL.md`, `docs/ARCHITECTURE.md`, `CHANGELOG.md` — prose that four lanes
  edited in the same place.
- `handover.md` — four lanes' deferrals, merged the way `skills/handover` documents: added to,
  never overwritten.

## Open questions

None.
