# Plan — report which roots the gate checked, and whether they overlap the diff

Contract: `task.md`. Seven steps, in order. Each one is checkable on its own.

The shape of the change: `lib/run_gates.sh` learns to say *where* it ran; a new
`lib/gate_coverage.sh` turns that plus the changed paths into a verdict; `skills/implement`
runs it and names the new outcome; the journal carries it. No exit code changes anywhere.

## The output contract, decided up front

Everything downstream parses these, so they are fixed here rather than invented per step.

`lib/run_gates.sh` gains three line shapes on stdout, all stable and greppable:

```
COVERAGE root=<root-relative dir> check=<label>
COVERAGE undeclared check=.claude/gates.sh
== coverage roots=<comma-list|UNDECLARED|NONE> heuristic=dirs-checks-ran-in-not-files-they-read ==
```

- The per-check line is emitted the moment a check runs, so a transcript that was cut short
  still shows what had been covered. `<dir>` is `.` for the repo root and root-relative
  otherwise (`bot`, `app/api`), matching the prefix `gates_in_dir` already builds.
- `undeclared` and `root=` are distinct keys, so a directory literally named `UNDECLARED`
  cannot be mistaken for the sentinel.
- The summary line is emitted on **every** exit path — all nine — so a parser always has
  exactly one to read.
- The `heuristic=` token is part of the line, not a pointer to prose elsewhere. A captured
  transcript is the primary consumer and it never carries the file's header comment, so a
  cross-reference there would dangle.

`lib/gate_coverage.sh` prints, one per line:

```
COVERAGE-ROOTS: <space-separated roots, or UNDECLARED, or NONE>
CHANGED: <count of changed paths considered>
EXCLUDED: <count of run-artifact paths skipped>
COVERED: <count matching a root>
VERDICT: overlap | no-overlap | undeclared | no-checks | no-changes | unknown
NOTE: heuristic — a root is the directory a check ran in, not the set of files it read.
```

`VERDICT` deliberately says nothing about pass or fail. The script does not know the gate's
colour; only the caller holds both halves. `green-but-uncovered` is the *combination* of exit 0
and `VERDICT: no-overlap`, and it is named in the skill that holds both, not here.

`unknown` is the fail-closed value: the transcript carried no summary line, so nothing could be
determined. It must never be collapsed into `no-checks` — that would let a broken environment
read as "nothing needed checking".

## Step 1 — `lib/run_gates.sh` emits the roots

**What changes.** Add `COV_DIR` and a `cov_roots` accumulator (a space-delimited string, the way
the existing `seen` variable does it — bash 3.2, no associative arrays).

- **`COV_DIR` is initialised to `.` at declaration.** The script runs under `set -u`, so a
  `run()` reached with `COV_DIR` unset would abort the shell with status 1 — a green tree
  reported red, which under `--strict` burns a fix attempt on a phantom failure and is exactly
  the new refusal the task forbids.
- `gates_in_dir` sets `COV_DIR` from its `$1`: `.` when the directory is `$ROOT`, otherwise
  `${dir#"$ROOT"/}`.
- `run()` emits `COVERAGE root=$COV_DIR check=$label` alongside its existing `== gate: ... ==`
  header, and folds `$COV_DIR` into `cov_roots` if it is not already there.
- The root `Makefile` fallback calls `run()` from outside `gates_in_dir`, so it resets
  `COV_DIR="."` explicitly first. Without that it inherits whichever subproject the scan visited
  last and mislabels itself.
- A `coverage_summary()` helper prints the summary line, and a `die_env()` helper prints it and
  exits 2, replacing the bare environment exits. Every one of the nine exits is then covered:
  unknown argument, not-a-git-repo, the `cd "$ROOT"` failure, the two `cd` failures inside
  `gates_in_dir`, the repo-owned branch, both `NO-GATES` branches, and the normal tail.
- The repo-owned branch prints `COVERAGE undeclared check=.claude/gates.sh` and a summary
  reading `roots=UNDECLARED` before it exits. It cannot honestly say more: the file is opaque by
  design, and reporting it as zero roots or as every root would both be lies in a direction that
  matters.
- Both `NO-GATES` exits print `roots=NONE`.
- The file header comment gains a paragraph on what a root does and does not prove.

**Not an `EXIT` trap**, though that would give the every-exit invariant for free. `run_gates.sh`
uses command substitution (`$(js_pm)`, `$(normalize_rc ...)`, `$(cd ... && pwd)`), each of which
is a subshell that would fire an inherited `EXIT` trap — printing duplicate summary lines and,
worse, capturing one *inside* the substitution and corrupting its value. Explicit calls are
uglier and correct.

**Exit codes are untouched.** No branch gains or loses one. Step 4 asserts this directly.

**How I know it worked.** In a fixture monorepo with a detectable subproject, the transcript
carries one `COVERAGE root=` line per check that ran and one summary naming the distinct roots;
a fixture with `.claude/gates.sh` carries `UNDECLARED`; a fixture with nothing carries `NONE`.

## Step 2 — `lib/gate_coverage.sh` computes the overlap

**What changes.** New script. Arguments:

```
bash lib/gate_coverage.sh --transcript <file> [--base <ref>] [--include-run-artifacts]
```

**Roots** come from the transcript's summary line — one place, not two. No summary line at all
yields `VERDICT: unknown` and a stated reason, never a number.

**Changed paths** are `git diff --name-only <base>` — **two dots, against the working tree** —
plus `git ls-files --others --exclude-standard`, deduplicated. This is the correction the
critique earned: three-dot is a commit-to-commit diff that ignores the working tree entirely,
and `skills/implement/SKILL.md` has no commit step — committing happens in ship. A gantry
worktree is cut fresh at its base, so at the moment this runs `HEAD` *is* the base and a
three-dot diff returns the empty set. Verified in this worktree: three-dot returned nothing
while two-dot returned the two files actually changed. The feature would have been blind to the
exact scenario it was built for.

**Base resolution** is a ladder, and its last rung is the one that matters:

1. `--base <ref>` when given;
2. the merge base with `@{upstream}` when an upstream exists;
3. the merge base with `refs/remotes/origin/HEAD` when that symbolic ref is set;
4. otherwise **`HEAD`**.

Rung 4 is not a failure case, it is the normal one. Every gantry worktree is created with
`git worktree add --no-track`, so rung 2 fails **by design** on every lane, and `origin/HEAD` is
set by `clone` rather than by `init` — so it is absent in every `tests/lib.sh` fixture too.
Falling back to `HEAD` with a two-dot diff yields "everything not yet committed", which is
precisely the changed set the implement phase has. A base that cannot be resolved therefore
never yields a silently empty answer.

**Run artifacts are excluded by default** and counted separately on the `EXCLUDED:` line:
`task.md`, `plan.md`, `handover.md`, `journal.jsonl`, and anything under `.claude/artifacts/`.
These are the orchestrator's own bookkeeping, they are untracked in a fresh worktree, and they
sit under no gate root — so counting them would drag every run toward "uncovered" and make
`"changed":3` read to a human as three source files. `--include-run-artifacts` turns the
exclusion off; the count is always reported so the exclusion is never invisible.

**Overlap is prefix matching**: a changed path is covered when a root is `.`, or when the path
starts with `<root>/`. Nothing cleverer, because nothing cleverer would be honest.

**The header comment states the limits plainly**: a root is the directory a check *ran in*, not
the set of files it *read*; a suite rooted in a subdirectory may import from the repo root and
cover more than this reports; a check that ran at the root covers every path by this measure
while possibly reading almost none of them; and a path containing a space or a comma corrupts
the delimited accumulator. The number is a heuristic in both directions.

**How I know it worked.** Run it against a step 1 transcript and a fixture with a known changed
set; the counts and the verdict are what prefix matching gives.

## Step 3 — `skills/implement/SKILL.md` reports the overlap

**What changes.** Step 5 gains, after the existing exit-code table:

**The invocation form is pinned, and this is load-bearing.** The gate must be captured with a
redirect and its status read immediately:

```bash
bash "$GANTRY/lib/run_gates.sh" --strict >"$log" 2>&1; rc=$?
```

Never a pipe. `bash run_gates.sh --strict | tee "$log"` yields **`tee`'s** exit status, so a red
gate reads as 0, `status: implemented` gets set, and the run pushes a broken tree. The exit code
of that one command is this project's entire guarantee, and changing how it is invoked without
saying this is how it would be lost.

Then run `lib/gate_coverage.sh` against `$log` and route on a table covering **all six**
verdicts — the earlier draft mapped four, and an unmapped verdict is one a reader will quietly
report as ordinary green:

| `VERDICT` | What to say |
|---|---|
| `overlap` | ordinary green |
| `no-overlap` | **green-but-uncovered** — still green, still exit 0, nothing refused, but the run has no evidence about the paths it changed, and the report must say so |
| `undeclared` | the repo owns its gate and did not declare what it covers; report that, do not guess |
| `no-checks` | pairs with the existing `NO-GATES` row; not a new condition |
| `no-changes` | the gate ran against an unchanged tree; report it, do not read it as coverage |
| `unknown` | the transcript carried no summary line; report that the overlap could not be determined, and never as green-with-coverage |

Plus one sentence in the body that the overlap is a heuristic and what makes it imprecise — this
is the surface most likely to be read without the script, so the caveat cannot live only in a
header comment.

The Report section gains the coverage verdict beside the exit code, and the roots, changed and
covered counts, phrased so a green-but-uncovered run cannot be reported as plain green. Those
values are also what the orchestrator needs in step 5; naming them here is what gives the
journal field a source.

Kept small: the body is long already and house style caps bodies at 500 lines.

**How I know it worked.** The body names green-but-uncovered, covers six verdicts, pins the
redirect, labels the heuristic, and adds no refusal.

## Step 4 — the tests

**What changes.** New `tests/cases/gate_coverage.sh`, matched by the existing `gate` name filter
so `bash tests/run.sh gate` runs it. Using `tests/lib.sh`'s fixture builders and `stub_cmd` so
nothing depends on a real toolchain:

1. a monorepo fixture with a root manifest and a subproject manifest — one `COVERAGE root=` line
   per check that ran, naming both `.` and the subproject, and a summary listing both;
2. a `.claude/gates.sh` fixture — `roots=UNDECLARED` present, **and** `roots=NONE` absent **and**
   the per-check key `root=` absent. The earlier draft's "does not claim zero or every root" had
   no observable form and would have passed vacuously under any regression;
3. a fixture with nothing detectable — `roots=NONE`, and the exit codes still 0 lenient and 3
   under `--strict`;
4. **the load-bearing one:** a green gate rooted in a subdirectory against a change touching only
   paths outside it — `VERDICT: no-overlap` **and `rc 0` under `--strict`**. This is the case the
   task is about, and the `rc 0` half is the assertion that no refusal was added;
5. an overlapping change against the same fixture — `VERDICT: overlap`;
6. untracked-only changes — counted, since the phase running this has usually not committed;
7. **the `make:test` fallback's `COV_DIR`** — a fixture whose only check is a root `Makefile`
   reached after a subproject scan, asserting the root check is labelled `.` and not the last
   directory scanned. Step 1 calls this the failure the change exists to expose; without a case,
   dropping the explicit reset ships green;
8. a transcript with no summary line — `VERDICT: unknown`, not `no-checks`.

The honest check on a new case is that it fails before the change and passes after. Cases 1–3
and 5–8 fail against the pre-change scripts because the lines and the script do not exist yet.
**Case 4's `rc 0` half passes both before and after** — it is a regression net for a refusal
nobody has added, which is what it is for, and saying otherwise would overstate the suite.

**What does not get a test.** The skill bodies and the journal reference are prose; nothing in
this repo tests prose, and inventing a harness for it here would be a second change wearing the
first one's clothes. Acceptance criterion "every surface labels it a heuristic" is routed to
`human_only` for that reason.

**This repo cannot exercise the load-bearing path on itself.** gantry gates itself with
`.claude/gates.sh`, so `run_gates.sh` here always takes branch 1 and reports `UNDECLARED`.
Confirmation lives in fixtures; do not expect in-situ proof.

**How I know it worked.** `bash tests/run.sh gate`, then `bash tests/run.sh`, then
`bash scripts/verify.sh` — all green, and all run **unsandboxed**, because `verify.sh` shells out
to `mktemp -d` and a sandboxed run fails there for reasons unrelated to the change.

## Step 5 — the journal field and its producer

**What changes.** Two files, because a documented field with no producer is worse than no field.

`skills/auto-unattended/references/journal.md`, in the `gate` event shape: a `coverage` object
beside the existing fields, per that file's own extension rule — a new field on an existing
event rather than a new event type.

```json
"coverage":{"roots":["bot"],"verdict":"no-overlap","changed":3,"covered":0,"heuristic":true}
```

`roots` is always an array, empty when the verdict is `undeclared`, `no-checks` or `unknown`, so
a parser never handles a string-or-array. The prose says what each field means, that `verdict`
mirrors `lib/gate_coverage.sh`, and that the number is a heuristic with the same caveat as
everywhere else — a reader reaching the journal alone must not be able to mistake it for a proof.

`skills/auto-unattended/SKILL.md` stage 4 is where the `gate` event is actually written, and it
currently says to journal the literal exit code and nothing more. It gains a clause naming the
`coverage` object and pointing at the implement phase's report as its source. Without this the
acceptance criterion "the gate event carries the coverage roots and the overlap verdict" has no
producer at all, and the field would be documented and never emitted.

**How I know it worked.** The documented shape matches what this run's own journal lines carry.

## Step 6 — `docs/ARCHITECTURE.md`

**What changes.** It hard-codes `lib/ shared runtime scripts (2)` with a two-entry inventory and
a paragraph reading "`lib/` exists because **two** scripts are shared". Adding
`lib/gate_coverage.sh` makes both wrong. `CONTRIBUTING.md` requires docs updated in the same
commit, and no automated check catches this — verified by reading the file.

**How I know it worked.** The count and the inventory name three scripts.

## Step 7 — the whole gate, unsandboxed

`bash tests/run.sh gate`, `bash tests/run.sh`, `bash scripts/verify.sh`. Green is the exit
condition for the phase.

## Order and why

1 before 2 because the comparison parses what the gate emits. 2 before 3 because the skill runs
the script. 4 after 1 and 2 because it tests both. 5 and 6 last: they document what the first
four established, and documenting a shape before it exists is how the two drift.

## Grilled

Critic: `gantry-critic`. Sixteen findings — 4 blocking, 9 worth fixing, 3 noted. What changed:

- **Three-dot diff cannot see the change** (blocking) → step 2 now specifies a two-dot diff
  against the working tree. Verified empirically in this worktree: three-dot returned the empty
  set, two-dot returned the actual changes. The feature was blind to its own motivating case.
- **`--base` had no resolvable fallback** (blocking) → step 2 gained an explicit four-rung
  ladder ending at `HEAD`. Every gantry worktree is `--no-track`, so `@{upstream}` fails by
  design, and `origin/HEAD` is absent in `init`-built fixtures. Confirmed: this worktree has no
  upstream.
- **Verdict table had no `no-changes` row** (blocking) → the table now covers all six verdicts,
  including a new fail-closed `unknown`.
- **Capturing the transcript could destroy the exit code** (blocking) → step 3 pins
  `>"$log" 2>&1; rc=$?` and says in terms why a pipe to `tee` would silently report a red gate
  as green.
- **The summary line missed five of nine exits** → step 1 adds `coverage_summary()` and
  `die_env()` and enumerates all nine. An `EXIT` trap was considered and rejected in writing:
  command substitution would fire it in subshells and corrupt captured values.
- **`COV_DIR` unset under `set -u`** → initialised at declaration. This one would have turned a
  green tree red, i.e. added the refusal the task forbids.
- **The journal field had no producer** → step 5 now also touches
  `skills/auto-unattended/SKILL.md` stage 4, and step 3 makes implement's report the source.
- **The changed set counted the run's own artifacts** → step 2 excludes them by default and
  reports the excluded count.
- **Test case 2's negative assertion could not fail** → replaced with assertions that can.
- **No test for the `make:test` `COV_DIR` reset** → added as case 7.
- **`docs/ARCHITECTURE.md` would go stale** → added as step 6.
- **"fix 3" in `task.md` referenced nothing** → the acceptance and out-of-scope wording now
  names the omission instead of numbering it.
- **The transcript's heuristic caveat pointed at prose stdout never carries** → the caveat is now
  a token on the summary line itself.

Left as noted, deliberately: delimiter fragility for paths containing a space or a comma (now
documented as a limit rather than engineered around — the alternative is a quoting scheme in
three languages for a case that does not occur in this repo); the unfalsifiable
"labels it a heuristic" criterion (routed to `human_only`, which is the right home for it); and
that this repo cannot exercise the load-bearing path on itself (recorded in step 4).
