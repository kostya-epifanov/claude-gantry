---
id: 2026-08-31-gate-coverage-report
title: Report which roots the gate actually checked, and whether they overlap the diff
project: claude-gantry
branch: feat/gate-coverage-report
mode: unattended          # semi-auto | auto | unattended — which mode is driving
status: shipped           # planning | planned | grilled | implementing | implemented |
                          # reviewed | shipped | blocked. The readiness hook arms on
                          # exactly `implementing` and ignores every other value.
---

## Context & goal

A gate that runs and passes while reading none of the paths the diff touches is reported
identically to one that proved something. Exit 0 is exit 0: `lib/run_gates.sh` prints
`== gates ran=N result=GREEN ==`, `skills/implement/SKILL.md` reads the exit code and nothing
else, the journal records a pass, and an unattended run pushes on the strength of it.

This is not hypothetical. In a recent batch of runs on this repo, a documentation-only change
touched three markdown files while `.claude/gates.sh` ran the repo's shell and manifest checks —
green before the change and green after, whatever the markdown said. Another changed skill prose,
which `scripts/verify.sh` never reads. Both runs produced a green journal line and a pushed
branch, and the batch as a whole reported zero red rounds — a number that looks like quality and
is partly an artifact of gates that could not have failed.

`NO-GATES` is the honest version of this and it stops the run. A green gate with no overlap is
the dishonest version: it satisfies the strict path, produces a green journal line, and makes the
run's central claim — "the checks pass on this change" — technically true and substantively
empty.

The fix is to make the difference **visible**, not to refuse it. `run_gates.sh` already knows
every check it ran and which directory it ran it in; it emits none of that. So: emit the roots,
compare them against the paths the diff touches, and name the green-with-no-overlap case as its
own outcome. Nothing new is refused, and the exit codes are unchanged.

The overlap is a **heuristic** and must be labelled as one everywhere it appears. Mapping a check
to the files it reads is per-ecosystem and imprecise: a pytest suite rooted at `bot/` may import
from the repo root, and a check that ran at the root covers every path by this measure while
possibly reading almost none of them. Reporting a heuristic is safe. Refusing on one is not — and
a reader who mistakes the number for a proof is exactly the failure this task exists to prevent,
one level up.

## Acceptance criteria

- [ ] `bash lib/run_gates.sh` in a fixture monorepo prints, on a stable greppable line, the
      root-relative directory each check it ran was run in.
- [ ] A repo with `.claude/gates.sh` reports its coverage as **undeclared** — not as zero roots,
      and not as every root.
- [ ] A repo where nothing is detectable reports no coverage roots, and its exit code is
      unchanged (0 lenient, 3 under `--strict`).
- [ ] `bash lib/run_gates.sh --strict` on a green gate whose roots do not overlap the changed
      paths still exits **0**. No new refusal, no new exit code.
- [ ] A deterministic script turns the gate transcript plus the changed paths into an overlap
      verdict, and `skills/implement/SKILL.md` step 5 runs it and reports the result.
- [ ] `skills/implement/SKILL.md` names **green-but-uncovered** as an outcome distinct from
      green, and says it is still green.
- [ ] The `gate` event in `journal.jsonl` carries the coverage roots and the overlap verdict, and
      `skills/auto-unattended/references/journal.md` documents the field.
- [ ] Every surface that carries the overlap — the gate transcript, the comparison script, the
      implement skill body, the journal reference — labels it a heuristic and says why it is
      imprecise.
- [ ] `bash tests/run.sh gate` covers the new output, and fails against the pre-change scripts.
- [ ] `bash tests/run.sh` and `bash scripts/verify.sh` are green.

## How to verify

```yaml
verification:
  automated:
    lint: true            # bash scripts/verify.sh — shellcheck, links, manifests
    tests: true           # bash tests/run.sh gate, then bash tests/run.sh
  human_only:
    - "the heuristic is labelled as one on every surface a reader can reach it from"
    - "the pull request body states that making zero overlap a refusal was deliberately
       left out, and why"
```

Run all three unsandboxed: `scripts/verify.sh` shells out to `mktemp -d`, and a sandboxed run
fails there for reasons that have nothing to do with the change under test.

## Out of scope

- **Any new refusal or exit code.** Zero overlap must not become a failure, under `--strict` or
  otherwise. It would fire on every legitimate documentation-only change, and it needs an
  override design before it could be considered at all. Making the gate refuse on zero overlap
  is the deliberate omission here, and the pull request body names it as such rather than
  leaving it implicit.
- A coverage-declaration contract for repo-owned gates — a way for `.claude/gates.sh` to say what
  it covers. Undeclared is the honest report today; a declaration format is separate work.
- `hooks/readiness-gate.sh`. It runs the same script out of band and inherits the new transcript
  lines for free; nothing about the hook changes.
- Surfacing green-but-uncovered in the pull request body. `gantry:ship` owns that file and it is
  another branch's change. This task leaves the signal in the implement phase's report, where
  that work can pick it up.
- Precise per-check path analysis — resolving what a pytest suite actually imports, or what a
  lint config actually globs. That is the thing this task explicitly does not claim to do, which
  is why the output is labelled a heuristic.

## Affected areas

- **`lib/run_gates.sh`** — the whole change on the emitting side. Three paths need a coverage
  line: the repo-owned `.claude/gates.sh` branch, which exits early and can only report
  undeclared; the auto-detect path, where `gates_in_dir` already receives the directory and
  `run()` already has the check label; and the `NO-GATES` branch, which exits before the current
  summary line. `run()` is also called once outside `gates_in_dir` for the root `Makefile`
  fallback, so whatever carries the current directory has to be set for that call too.
- **`lib/gate_coverage.sh`** *(new)* — the comparison. Prefix-matching root-relative paths
  against roots is deterministic and repeated, which house style puts in a script rather than in
  a skill body, and a script is what `tests/run.sh` can exercise.
- **`skills/implement/SKILL.md`** — step 5 and the Report section. Step 5 currently reads the
  exit code alone.
- **`skills/auto-unattended/references/journal.md`** — the `gate` event shape.
- **`skills/auto-unattended/SKILL.md`** — stage 4 is where the `gate` event is actually written,
  and it says to record the exit code and nothing else. Documenting a field whose producer is
  never told to emit it would leave the criterion unmet, so the clause is added there.
- **`docs/ARCHITECTURE.md`** — hard-codes `lib/ shared runtime scripts (2)` and a paragraph
  reading "two scripts are shared". A third script makes both wrong, and house style requires
  the docs to move in the same commit.
- **`tests/cases/gate_coverage.sh`** *(new)* — picked up by the `gate` name filter, so
  `bash tests/run.sh gate` runs it.
- **Risks.** `scripts/verify.sh` runs `shellcheck -S warning` over every tracked shell file, and
  the suite targets bash 3.2 — no associative arrays, no `mapfile`. Accumulating distinct roots
  has to be a delimited string, the way the existing `seen` variable already does it. Fixture
  repos must never carry an absolute developer path; `scripts/secret-scan.sh` fails on one.
- **Known conflicts with work in flight.** Another branch edits the Report paragraph of
  `skills/implement/SKILL.md`; another edits a different event section of
  `references/journal.md`. Both are additive and expect a trivial rebase.

## Open questions

- [x] Should zero overlap refuse under `--strict`? — **No, decided by the task itself.** It would
      fire on legitimate documentation-only changes and needs an override design first. Reporting
      a heuristic is safe; refusing on one is not. Named in the pull request body as deliberately
      left.
- [x] Where does the comparison live — inline in the skill body, or a script? — **A script,**
      `lib/gate_coverage.sh`. House style puts anything deterministic in a script, and the
      comparison is prefix matching over two path lists. It also makes the behaviour testable by
      `tests/run.sh`, which a paragraph of skill prose is not. This adds a file beyond the three
      the task names; the addition serves those three rather than widening the change.
- [x] What does the comparison use as the base for "the paths in the diff"? — **The merge base
      with the branch the worktree was cut from,** with the changed set taken as tracked changes
      plus untracked files. The script takes the base as an argument and defaults to a detected
      one, so the skill does not hardcode a branch name.
- [x] Should the coverage roots be a list or a single summary? — **Both.** One line per check
      that ran, carrying its directory and label, plus one summary line naming the distinct
      roots. The per-check lines are what make the summary auditable; the summary is what a
      parser reads.
