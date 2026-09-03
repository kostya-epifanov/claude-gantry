---
id: 2026-09-02-deliberate-review
title: Make ship's review deliberate, and rework review as a thin /code-review wrapper
project: claude-gantry
branch: feat/v0.4.1
mode: semi-auto           # semi-auto | auto | unattended — which mode is driving
status: implemented            # planning | planned | grilled | implementing | implemented |
                          # reviewed | shipped | blocked. The readiness hook arms on
                          # exactly `implementing` and ignores every other value.
---

## Context & goal

`gantry:ship` currently runs `/code-review` as part of its default path: commit, review, push,
open a PR. That makes the expensive, slow, judgement-heavy step the thing you get by accident.
Someone who wants only to get a branch pushed pays for a review they did not ask for, and the
usual escape is `--reviewed`, a flag whose meaning is "lie to the skill so it stops". A step that
most invocations want to skip is not a default; it is a tax with an opt-out.

This task inverts that. Review becomes something you ask for: bare `/gantry:ship` commits, pushes
and opens the PR without ever invoking a reviewer, and two new flags make the request explicit —
`--review` runs `gantry:review`, `--review-fix` runs it in its fix-applying mode. The point is
that a review appearing in the transcript should mean somebody chose it.

The second half is `gantry:review` itself. Today it carries its own review logic and two long
paragraphs whose only job is to explain why ship's copy of a review behaves differently. Removing
ship's stage makes that reasoning obsolete rather than merely stale, and what is left is the thing
the skill should always have been: choose a tier, dispatch `/code-review`, verify what comes back,
triage it against the task contract, act. `--tier` (`medium` | `high` | `xhigh` | `max`, default
`high`) makes the depth an explicit dial instead of whatever `/code-review` last remembered.

Two decisions shape the rest. **Review becomes read-only by default** — it reviews, triages and
reports, and only `--fix` lets it write. That is what makes ship's `--review` and `--review-fix`
genuinely different requests rather than two names for the same side effects. And **no finding is
reported or acted on until it has been verified against the repo**: reviewers, including good
ones, report things that are not true, and an unverified finding costs the reader more than it
saves whether it arrives as a fix or as a line in a report.

## Acceptance criteria

- [ ] `/gantry:ship` with no flags completes its full path (commit → push → PR) without invoking
      `/code-review` or `gantry:review` at any point.
- [ ] `/gantry:ship --review` invokes `gantry:review` between the commit and the push, and a
      review that blocks stops the ship rather than pushing anyway.
- [ ] `/gantry:ship --review-fix` invokes `gantry:review --fix`.
- [ ] `--review=<tier>` and `--review-fix=<tier>` pass exactly that tier to `gantry:review`; the
      bare forms mean `high`.
- [ ] Ship re-runs `detect_state.sh` after **either** review flag before pushing. Both can move
      the tree — `--review-fix` through its fixes, `--review` through `handover.md` — so the read
      the push and PR stages use is never one taken before the review.
- [ ] `skills/ship/SKILL.md`'s `allowed-tools` carries `Agent` and `AskUserQuestion`, which
      `gantry:review` needs and ship does not currently grant.
- [ ] `/gantry:review` with no arguments invokes `/code-review` at tier `high`.
- [ ] `/gantry:review --tier <medium|high|xhigh|max>` passes exactly that tier to `/code-review`.
- [ ] `ultra` is refused by name, for the reason the skill already gives — it is billed and
      user-triggered, and an unattended run has nobody present to authorise it.
- [ ] Any other tier value is rejected with a message naming the valid values, and nothing is
      dispatched — it does not silently fall back to `high`. This holds for both `--tier` and the
      `--review=<tier>` form.
- [ ] `/gantry:review` without `--fix` makes **no change to the code under review**. Its only
      writes are gantry's own artifacts: `task.md`'s status, always, and `handover.md` when
      something was deferred.
- [ ] `/gantry:review --fix` applies the address-now findings and re-runs the gate afterwards,
      with a red gate stopping the phase.
- [ ] Every finding is checked against the repo before it is reported or fixed; a finding that
      does not survive that check is dropped and counted, never listed as a finding.
- [ ] Both drivers still get a fixing review: whatever they pass, the supervised and unattended
      chains apply in-scope findings and re-run the gate exactly as they do today.
- [ ] `--reviewed` is gone from ship, both drivers and the docs — a recursive grep for it over
      `skills/`, `docs/` and `README.md` returns nothing. The sweep is scoped: `task.md`,
      `plan.md` and `CHANGELOG.md` name the flag legitimately, the last as release history that
      must not be rewritten.
- [ ] `scripts/verify.sh` carries two new sweeps, in the shape of its existing banned-vocabulary
      check: `skills/ship/SKILL.md` contains no `/code-review` invocation, and `--reviewed`
      appears nowhere — both excluding `task.md`, `plan.md` and `CHANGELOG.md`.
- [ ] `bash scripts/verify.sh` passes.

## How to verify

**Three of the criteria above are mechanical; the rest are not, and the honest thing is to say
which.** `scripts/verify.sh` — including the two new sweeps — proves that ship's SKILL.md no longer
invokes `/code-review`, that `--reviewed` is gone, and that the plugin still parses, links resolve
and the descriptions fit the budget. Every criterion describing what a skill *does at runtime* is
established by reading the prose, because nothing in this repo executes a SKILL.md.

```yaml
verification:
  automated:
    lint: true
    tests: true
  human_only:
    - "Read skills/ship/SKILL.md end to end as an operator who wants only a push: the bare path
       never mentions a review, and the two new flags read as the deliberate opt-in they are."
    - "Read skills/review/SKILL.md end to end: it reads as dispatch → verify → triage → act, with
       no paragraph left explaining another skill's behaviour, and the read-only default stated
       where a skimming reader will hit it."
    - "Walk ship's five entry stages (commit, push, pr, done, no-diff) against --review and
       --review-fix: each one either runs the review somewhere useful or says why it does not.
       An explicitly requested review must never silently not happen."
    - "Confirm the supervised and unattended chains still apply review findings end to end — the
       read-only default is the change most likely to regress the drivers silently."
```

## Out of scope

- **No slot mechanism, and no new review agents.** The named review dimensions (conventions,
  style, architecture, security) and any lookup that would dispatch an agent per dimension are
  deliberately deferred — decided during planning, having been in the original brief. This change
  makes `gantry:review` thin; adding dimensions to it is a separate task against a skill that is
  by then simple enough to extend. `agents/` keeps exactly its current three files.
- **No change to what `/code-review` itself does.** This task chooses a tier and dispatches; the
  reviewer's own behaviour, output shape and finding quality are upstream.
- **No change to the gate.** `lib/run_gates.sh`, `hooks/readiness-gate.sh` and the `--strict`
  exit-code contract are untouched. Review's relationship to the gate (re-run after any fix) is
  preserved exactly as it is.
- **No change to ship's other stages.** Commit, push, PR-open, the stage-5 disclosure checks and
  the `--no-pr` / `--draft` / `--base` flags keep their current behaviour. Only the review stage
  and the flags that reach it are in play.
- **No change to `gantry:handover`.** Review still hands deferrals to it, unchanged.
- **No harness that executes a SKILL.md.** Asserting on which sub-skill a model actually chose to
  invoke at runtime is its own project. What *is* in scope, decided during grilling, is the two
  static sweeps in `scripts/verify.sh` — they catch the regression that matters (ship's default
  path regaining a `/code-review` call) without pretending to execute anything.
- **No rename of `task.md`'s `status:` vocabulary.** `reviewed` still means reviewed, whether or
  not `--fix` was passed. The status write is what `detect_stage.sh` reads to know the chain has
  moved on, and moving it under `--fix` would strand a bare review outside the state machine.
- **Not a general flag-parsing library.** Each skill keeps parsing `$ARGUMENTS` in prose, the way
  every other gantry skill does today.

## Affected areas

**The two skills being changed**

- `skills/ship/SKILL.md` — the largest component in the repo. Its stage 3, *Review the change*, is
  the thing being removed; the flag prose near the top documents `--reviewed`; stage 1's routing
  notes say `push`/`pr` "skip to stage 3" and warn that stage 3 can commit and so forces a
  re-detect before the push; the `--no-pr` paragraph explains what is traded away with the review;
  the Report section names the review and the `/code-review`-unavailable case; and the `gh
  missing`/`unauth` recovery advice tells the user to re-run with `--reviewed`. Every one of those
  moves together — a stage removed but still referenced from five places is worse than one left in.
- `skills/review/SKILL.md` — step 2 currently ranks three tiers and contains two paragraphs that
  exist only to explain the `--fix` asymmetry with ship (*"`gantry:ship` **does** pass `--fix`, and
  that is not a contradiction…"*). Removing ship's review stage makes that reasoning obsolete
  rather than merely stale. Step 3's triage against *Out of scope* is what a `--fix` mode has to
  reckon with.

**The callers that will contradict the change if left alone**

- `skills/auto/SKILL.md` and `skills/auto-unattended/SKILL.md` — both invoke `gantry:ship
  --reviewed` and both carry a paragraph justifying why `--reviewed` "is not optional here".
- `skills/auto/references/orchestration.md` — the flag table and the ship delegation notes repeat
  the same justification a third time.
- `skills/auto-unattended/references/delegation.md` — the gate table says ship re-runs the gate
  "in the one case where its review stage changed the tree", which stops being true.

**Docs that state the old behaviour as fact**

- `README.md` — the skill table row for `/gantry:ship` says "commit, review with `/code-review`,
  push, open PR", and the mermaid diagram has a `if /code-review is absent` edge into
  `gantry-reviewer`.
- `docs/SKILLS.md` — the `/gantry:ship` reference block, its argument line, the paragraph
  describing `/code-review --fix` between commit and push, and the gate-recheck note.
- `docs/ARCHITECTURE.md` — the note that the review stage is "skipped entirely by `--no-pr` or
  `--reviewed`", and the resume-with-`--reviewed` advice.
- `CHANGELOG.md` — a 0.4.1 entry; the file already documents the stage this change removes.
- `.claude-plugin/plugin.json` — carries the version the branch name implies.

**Risks**

- **The always-on context budget is the tightest constraint.** `scripts/context_budget.sh` counts
  skill and agent description characters against a ceiling of 6250; the tree sits at 5783, leaving
  **467 characters**. Ship's description is the single largest at 735 and review's is 314, and both
  must change — ship loses its review clause and gains two flags, review gains `--tier` and the
  slot vocabulary. It is entirely possible to write both honestly and go over. Budget headroom is
  a design constraint on the wording here, not an afterthought.
- **No gate can prove the headline criterion.** `scripts/verify.sh` checks shell syntax, JSON,
  frontmatter/directory agreement, link resolution, line-number citations and the fixture-backed
  gate and hook behaviour. Nothing in it executes a SKILL.md. That bare `/gantry:ship` no longer
  invokes a reviewer is verified by reading, and by the human-only checks in this contract.
- **`claude plugin validate skills --strict`** runs over the frontmatter, so `argument-hint`
  changes on both skills have to stay well-formed.
- **Link and citation checks bite on prose edits** — `verify.sh` fails on any `.md:<line>` citation
  and on relative links that do not resolve, both of which are easy to introduce while moving
  paragraphs between files.
- **`--reviewed` is load-bearing in six places.** Whatever is decided for it, a half-applied
  decision leaves the drivers passing a flag ship no longer documents.

## Open questions

- [x] What happens to ship's `--reviewed` once there is no review stage to skip? — **Removed
      entirely**, from ship's frontmatter, prose and argument-hint, and from both drivers and the
      orchestration docs. The flag existed only to suppress a stage that no longer exists.
- [x] Can ship choose the review tier? — **Yes, as value syntax on the flag**: `--review=<tier>`
      and `--review-fix=<tier>`, with the bare forms meaning `high`. No separate `--tier` on ship;
      that flag stays on `gantry:review`, where it is the skill's own dial.
- [x] What is a "slot", concretely? — **No slots for now.** The mechanism is dropped from this
      change rather than shipped empty; see *Out of scope*.
- [x] What should `--fix` mean on `gantry:review`? — **Report-only by default, `--fix` applies.**
      Review becomes non-mutating unless asked; `--fix` applies the address-now findings that
      survive triage. It is not passed through to `/code-review`, so triage still decides what the
      change absorbs. Added with it: **findings must be verified before they are reported or
      fixed**, not only before they are acted on.
- [x] Raised during grilling: what may a bare, non-`--fix` review write, given that it invokes
      `gantry:handover` and writes `task.md`'s status, which `detect_stage.sh` reads? — decided:
      gantry's own artifacts only. Never the code under review; always the status; and
      `handover.md` when something was deferred. This keeps the chain's state machine and the
      artifact both drivers journal. Its knock-on is a criterion above: ship must re-detect after
      either review flag, because `--review` can move the tree too.
- [x] Raised during grilling: should the `--reviewed` and `/code-review` sweeps be wired into
      `scripts/verify.sh` rather than left as greps a human runs once? — **Yes, both**, in the
      shape of the existing banned-vocabulary check. This narrows *Out of scope*, which now
      excludes only a harness that executes a SKILL.md.
