---
id: 2026-08-31-verify-sees-untracked-files
title: Make verify.sh enumerate untracked files, so the gate sees what the run just wrote
project: claude-gantry
branch: fix/verify-sees-untracked-files
mode: unattended          # semi-auto | auto | unattended — which mode is driving
status: shipped           # planning | planned | grilled | implementing | implemented |
                          # reviewed | shipped | blocked. The readiness hook arms on
                          # exactly `implementing` and ignores every other value.
---

## Context & goal

`scripts/verify.sh` is the whole of this repo's check surface: CI runs the same script, so
CONTRIBUTING states plainly that a green local run means a green CI run. Six of its checks
enumerate the files to inspect with `git ls-files`, which — with no flags — lists **tracked files
only**.

That is a false-green with a precise shape, and the pipeline walks into it every run. `implement`
runs the gate; `ship` does not commit until much later. So at gate time `task.md` and `plan.md`,
the two files the pipeline itself just wrote, are **untracked**, and three checks cannot see them:
the line-number-citation check, the forbidden-string sweep, and the relative-link check. Minutes
later `ship` commits them, CI runs the identical script, and now they are tracked — so CI fails on
files that the local gate reported clean. Green local, red CI, on the pipeline's own artifacts.

This is not hypothetical. `plan` step 3 tells the author to paste the explorer's output into
*Affected areas*, and the explorer returns citations of exactly the form the citation check
forbids: a docs path ending in `.md`, a colon, a line number. A lane that ran in this repo hit it
and stripped them by hand. Nothing in the pipeline would have caught it.

The same blindness covers anything else a run creates before the commit — a new `lib/*.sh` written
during `implement` is not syntax-checked or shellchecked either, which is the shape of a change
landing in this repo this week.

The fix is one flag set: enumerate with `git ls-files --cached --others --exclude-standard`, so
tracked *and* new-but-not-ignored files are inspected. `--exclude-standard` is what keeps the run's
own noise out. It honours three sources, and the differences between them matter: the repo's tracked
`.gitignore`, which already lists `journal.jsonl`, `.claude/artifacts/` and `.claude/worktrees/` and
therefore survives a fresh checkout in CI; each clone's own `.git/info/exclude`, which the drivers
write the same paths into and which exists only locally; and the contributor's global
`core.excludesFile`, which varies per machine. The durable protection is the tracked file, the local
one is belt-and-braces, and the global one is why two contributors can enumerate slightly different
file sets from the same tree.

## Acceptance criteria

- [ ] Every enumeration in `scripts/verify.sh` covers untracked, non-ignored files as well as
      tracked ones — all six sites, including the three that feed the shell-syntax, shellcheck and
      python-parse checks.
- [ ] In a fixture repo holding an **untracked** markdown file that carries a line-number citation,
      `scripts/verify.sh` reports the citation check as failed and names that file. Against the
      pre-change script the same fixture reports the check clean.
- [ ] In the same fixture, an **untracked** shell script with a syntax error is reported by the
      shell-syntax check. This is the criterion that covers the three syntax-side sites, and it
      needs no toolchain beyond `bash -n`.
- [ ] Markdown carrying the same citation is **not** reported when it is excluded — once via the
      tracked `.gitignore` and once via `.git/info/exclude`, so both mechanisms are asserted rather
      than assumed.
- [ ] A new case under `tests/cases/` asserts all of the above and is discovered automatically by
      `tests/run.sh`.
- [ ] The new case fails against the pre-change `scripts/verify.sh` and passes against the changed
      one — negative-tested, with the failing-assertion count recorded.
- [ ] `bash tests/run.sh` and `bash scripts/verify.sh` are both green on this repo.
- [ ] The new local-only failure mode — a red gate caused by untracked files CI will never see — is
      documented where a contributor reads it, since CONTRIBUTING currently claims the local run and
      the CI run agree.

## How to verify

```yaml
verification:
  automated:
    lint: true          # bash -n and shellcheck, via scripts/verify.sh
    tests: true         # bash tests/run.sh, which now includes verify_untracked
  human_only: []        # every claim above is asserted by the suite
```

Run, from the worktree root:

```bash
bash tests/run.sh verify_untracked   # the new case alone
bash tests/run.sh                    # the whole suite
bash scripts/verify.sh               # the gate
```

The pull request body additionally quotes the exclusion demonstration — the same two commands run
against this repo rather than a fixture — because a reviewer should be able to see the claim hold
without running anything. That is a courtesy to the reader, not the evidence: the evidence is the
assertion in the suite.

## Out of scope

- **What the checks look for.** No new swept strings, no new rules, no relaxing of an existing
  rule to quiet a file that only just became visible. Newly-visible findings get fixed; the sweep
  does not get widened.
- **`.github/workflows/validate.yml`.** It invokes `scripts/verify.sh` and needs no change — the
  fix lands entirely inside the script it already runs.
- **`scripts/context_budget.sh`.** It enumerates with shell globs over `skills/` and `agents/`, not
  with git, so it already sees files that are not yet committed. No defect to fix.
- **`scripts/secret-scan.sh`.** It enumerates tracked files only, and unlike `verify.sh` that is a
  written, reasoned decision rather than an oversight — its header says untracked scratch is not
  being published. Changing the publish gate's scope is a separate judgement with its own
  false-positive risk, and is not this change. The blind spot it leaves — the same green-local
  /red-CI shape, on the same three files — is written up in `handover.md` rather than fixed here.
- **The producer side of the citation rule.** `gantry-explorer` still returns markdown paths with
  line numbers attached, and `plan` still says to paste that into *Affected areas* — so this change
  makes a gantry-on-gantry run go red locally where it used to go red in CI. Real, and a change to
  two files this contract does not name. Detail and remedy in `handover.md`.
- **The unguarded `mktemp -d` in `verify.sh`'s own fixture block.** Pre-existing, revealed by
  running the gate under a sandbox that denies temp-directory creation. Detail in `handover.md`.
- **Hardening the enumerations against an empty result.** Two sites pipe into `xargs`. BSD `xargs`
  does not run the utility on empty input; GNU `xargs` does, which would leave `grep` reading
  standard input. This change makes an empty list strictly less likely on a real repo, so the
  latent problem is untouched rather than introduced — but the new fixture must never construct it,
  and that constraint is carried in the plan.

## The limit this change introduces

Worth stating plainly, because it is the cost side of the trade and it points the wrong way from
everything else here.

The local gate now inspects files that are untracked and not ignored — which includes whatever a
contributor happens to have lying in their tree. An untracked virtual environment or dependency
directory that no ignore rule covers will have its shell scripts parsed and its files swept, and
can turn the gate red over something that has nothing to do with the change. Because the readiness
hook blocks on a red gate, an unattended lane can be held up by it.

This is accepted rather than worked around. The escape hatch already exists and is the ordinary git
one — add the path to `.gitignore` or `.git/info/exclude` — and narrowing the enumeration to dodge
it would restore exactly the blindness this change removes. It gets documented, not designed
around.

Note the direction: in CI the change is a **no-op**, because a fresh checkout has no untracked
files at all. Every bit of new coverage is local. That asymmetry is the point — the local gate now
sees what CI will see once the run commits — but it does mean CONTRIBUTING's "a green local run
means a green CI run" now needs its converse spelled out.

## Affected areas

Read directly rather than via an explorer: the surface is three scripts and one test harness, all
of which were read end to end.

- `scripts/verify.sh` — the six enumerations, at the shell-syntax check, the shellcheck check, the
  python-parse check, the citation check, the forbidden-string sweep, and the relative-link check.
  Two of them carry pathspecs that must survive the change: a `-z` form with a `:!scripts`
  exclusion, and three glob forms.
- `tests/run.sh` — discovers `tests/cases/*.sh` by glob, so a new case needs no registration.
- `tests/lib.sh` — supplies `mkrepo`, `CASE_TMP`, and the assertion helpers. It has no runner for
  `scripts/verify.sh`; the new case invokes the script directly and asserts on the section of
  output that this change is about.
- `scripts/secret-scan.sh` — the only other git-based enumeration in the repo. Deliberate, per
  above.
- `.gitignore` — already lists the three run-artifact paths. Read, not edited: it is the reason the
  exclusion holds in CI as well as locally.
- `CONTRIBUTING.md` — states that a green local run means a green CI run. Still true; the converse
  now needs a caveat.
- `CHANGELOG.md` — this is a behaviour change to the gate and belongs in the record.

Risks a change here runs into:

- **The gate is live for this run.** `.claude/gates.sh` invokes `scripts/verify.sh` by path out of
  the worktree, so the edited script gates its own change. Files that were invisible a moment ago
  become visible mid-run — including this very file and `plan.md`. Both were written to survive the
  sweep from the start.
- **Asserting on the exit code alone proves nothing.** A bare fixture repo fails `verify.sh` for a
  dozen unrelated reasons — no plugin manifests, no `skills/`, no suite to recurse into. The
  differential assertion has to be on the citation check's own line of output, with the exit code
  as a secondary check.
- **`grep` omits the filename when it is given a single operand.** A fixture whose entire markdown
  set is the one file under test produces `1:...` rather than `<file>:1:...`, so an assertion that
  the check names the offending file fails against the *fixed* script. The fixture has to carry a
  second, tracked, citation-free markdown file — which is also what keeps the enumeration non-empty
  and so keeps `xargs` off the empty-input path.
- **No recursion, but only by accident of location.** `verify.sh` cds to the git toplevel and runs
  `bash tests/run.sh`. A fixture built under the temp root is a different toplevel, so the nested
  invocation simply finds no such path and exits 127. A fixture built *inside* this repo would
  recurse without bound.

## Open questions

None. The task fixes the enumeration and nothing about what is enumerated for; the one judgement
call — whether `scripts/secret-scan.sh` shares the defect — is answered in *Out of scope* from its
own header comment rather than left open.
