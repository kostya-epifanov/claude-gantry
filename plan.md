# plan.md — make verify.sh enumerate untracked files

Five steps. One of them is a two-line change to a script; the rest exist because a check that has
never been observed to fail is not a check.

Revised after the grill pass. See **Grilled** at the end for what changed and why.

## The decisions worth stating up front

**One helper, not six edits.** The six call sites take different pathspecs — four globs and one
`-z` form with a `:!scripts` exclusion — but they want the identical enumeration. Six copies of a
four-flag incantation is six chances for the seventh site to be written without it, and it leaves
nowhere to put the reason. So the flags get one named definition near the top of
`scripts/verify.sh`, forwarding `"$@"` so every pathspec passes through unchanged, and the comment
explaining *why* untracked files are in scope lives beside it. Forwarding was checked against all
six pathspecs: git permutes options, so the `'*.sh' -z` and `-z -- ':!scripts'` forms both still
parse with the flags prefixed.

**The test asserts on a section, not on the exit code.** `scripts/verify.sh` in a throwaway fixture
repo exits non-zero regardless — no plugin manifests, no `skills/`, no suite for it to run. So
"exits non-zero" is vacuous there. What is not vacuous is a named check's own line of output: clean
before the change, failed after, on the same fixture. That is the differential.

**The fixture must never present an empty enumeration.** Two sites pipe into `xargs -0`. BSD
`xargs` skips the utility on empty input; GNU `xargs` — which is what CI's runner has — invokes it
with no operand, leaving `grep` reading standard input. A fixture with zero enumerable markdown
files would therefore block forever in CI, or pass vacuously where standard input is closed. So the
fixture carries a **tracked, citation-free** markdown file and a **tracked, valid** shell script in
every condition, and those two files are load-bearing rather than scenery.

**The exclusion claim gets asserted, not just demonstrated.** The change rests on
`--exclude-standard` keeping run artifacts out. That claim is asserted in the suite against *both*
mechanisms — the tracked `.gitignore`, which is what survives a fresh checkout, and the per-clone
`.git/info/exclude` — because crediting only the local one would teach the next reader that the
protection vanishes in CI, which is the opposite of true. The pull request body also quotes the
demonstration against this repo, for a reader who is not going to run anything.

## Step 1 — Add the enumeration helper and route all six sites through it

In `scripts/verify.sh`, beside the existing `ok`/`bad`/`head2` helpers, add:

```bash
repo_files() { git ls-files --cached --others --exclude-standard "$@"; }
```

with a comment stating the four things a reader needs: that `git ls-files` alone is tracked-only;
that the pipeline's own `task.md` and `plan.md` are untracked at gate time while CI sees them
committed, which is the false-green this closes; that `--exclude-standard` is what keeps
`journal.jsonl` and the gate artifacts out, via the tracked `.gitignore` first and
`.git/info/exclude` second; and that the price is a gate whose result now depends on what untracked
files are in the tree.

Then replace the six `git ls-files ...` invocations with `repo_files ...`, keeping every pathspec
and every `-z` exactly as it is. The sites are the shell-syntax loop, the shellcheck pipeline, the
python-parse loop, the citation check, the forbidden-string sweep, and the relative-link loop.

Include the three syntax-side sites. The ticket calls them arguable; they are not — a `lib/*.sh`
written during `implement` is exactly as invisible as an untracked `task.md`, and that is the shape
of a change landing in this repo now.

**How I will know it worked:** `git diff` shows six call sites converted and no pathspec altered;
`bash -n scripts/verify.sh` parses; `bash scripts/verify.sh` runs to completion.

## Step 2 — Fix whatever the newly-visible files legitimately fail

Running the gate after step 1 puts files inside the sweep that were never inspected before — this
run's own `task.md` and `plan.md` first, and anything else untracked in the tree.

Fix what is genuinely wrong. Do **not** add an exclusion, widen a rule, or relax a pattern to make
a newly-visible finding go away: that would convert a real defect into a permanently invisible one
and defeat the entire change. If something is wrong *and* out of scope to fix, it goes to a
handover, not into the sweep's exception list.

One consequence to watch for, since it bites at the worst moment: any scratch copy of
`scripts/verify.sh` kept for step 4 must live **outside the repository**. The forbidden-string
sweep excludes `scripts/` and nothing else, so a copy parked at the repo root or under `tests/`
is enumerated and matches every string the real script looks for, turning the gate red at the exact
step meant to prove the change works.

**How I will know it worked:** `bash scripts/verify.sh` reports the citation check, the
forbidden-string sweep and the relative-link check as clean, with no rule edited.

## Step 3 — Add `tests/cases/verify_untracked.sh`

`tests/run.sh` globs `tests/cases/*.sh`, so the file is the registration. Source `tests/lib.sh` for
`mkrepo`, `CASE_TMP` and the assertions, as every existing case does.

The fixture, built with `mkrepo` under `CASE_TMP` and committed:

- `docs/notes.md` — markdown with no citation. Present in every condition. It is the second `grep`
  operand that makes `grep` print filenames at all, and it keeps the markdown enumeration non-empty.
- `ok.sh` — a valid shell script, for the same reason on the `*.sh` side.
- `.gitignore` — listing the gate artifacts directory, mirroring this repo's own.

and locally, `.git/info/exclude` listing one scratch markdown path.

Two invocations of `scripts/verify.sh` inside that fixture:

**Condition A — untracked files present.** Write, without staging any of them: a markdown file
carrying a citation (a docs path ending in `.md`, a colon, a line number); a shell script with an
unterminated `if`; and two more markdown files carrying the same citation, one under the
gitignored artifacts directory and one at the `.git/info/exclude`d path. Assert:

1. the citation check reports failure **and** names the untracked markdown file — the acceptance
   criterion, and the one assertion that is false against the pre-change script;
2. the shell-syntax check reports failure and names the broken script — this is what covers the
   three syntax-side sites, and it costs nothing but `bash -n`;
3. neither excluded path appears anywhere in the output — both exclusion mechanisms, asserted.

**Condition B — the untracked offenders removed.** Assert the citation check reports clean, so the
case is proving the citation rather than the mere existence of a file.

The case carries a comment recording why the fixture must live under `CASE_TMP`: `verify.sh` cds to
the git toplevel and runs `bash tests/run.sh`, so a fixture built inside this repository would
recurse without bound.

Written against the constraints `tests/lib.sh` documents in its own header: bash 3.2, no absolute
developer paths, no dependency on an installed toolchain.

**How I will know it worked:** `bash tests/cases/verify_untracked.sh` alone is green, and
`bash tests/run.sh` reports one more case than before.

## Step 4 — Negative-test the case

The step that decides whether step 3 was worth writing. Copy the edited `scripts/verify.sh` to a
path **outside the repository**, restore the committed version in place, run the case, and record
how many assertions fail. Then put the edited version back and confirm the case is green again.

A case that passes against the unfixed script proves nothing, and this repo's convention — visible
in the changelog entry for the last case added — is that a new case is reported with the count of
assertions that fail before the fix.

**How I will know it worked:** a failing-assertion count I can quote, and a green case afterwards.

## Step 5 — Document the limit, then record the change

Two edits, both required by house style rather than optional polish.

`CONTRIBUTING.md` states that a green local run means a green CI run. That stays true. What is now
also true, and is not written anywhere, is the converse: a **red** local run no longer implies a
red CI run, because the local gate inspects untracked files that a fresh checkout does not have. A
contributor whose tree holds an untracked dependency directory can be blocked by it, and the fix is
the ordinary git one — ignore the path. Add that caveat next to the existing claim.

Then a changelog entry under a new *Unreleased* heading, in the repo's established voice: the
defect, the shape of the false-green, that the change is a no-op in CI and all of its new coverage
is local, and what it does not cover — `scripts/secret-scan.sh` still enumerates tracked files
only, on purpose.

**How I will know it worked:** `bash scripts/verify.sh` is green with both edits in place.

## Test strategy

- **Gets a test:** the citation check seeing an untracked file and naming it; the same check staying
  quiet when the citation is absent; an untracked shell script with a syntax error being caught;
  excluded files staying out of the sweep under both mechanisms. These are the claims the change
  makes.
- **Does not get a test:** the shellcheck and python-parse sites specifically. Both route through
  the same one-line helper as the sites that *are* asserted, and asserting on shellcheck would make
  the suite depend on shellcheck being installed — which `tests/lib.sh` explicitly warns against.
  The `bash -n` assertion is the syntax-side coverage; it needs no toolchain and exercises the same
  helper.
- **Does not get a test:** the pull-request-body demonstration. It is for a human reader; the
  machine-checkable half of the same claim is assertion 3 in condition A.
- **Named cost, not hidden:** each condition runs the whole of `verify.sh` inside the fixture, which
  means four `jq` invocations, up to four `claude plugin validate` calls where the CLI is present,
  and a nested temp repo of its own. Two conditions, so twice that — inside `tests/run.sh`, which
  `verify.sh` itself invokes. Nothing hangs and nothing recurses, but the case is the most expensive
  in the suite and asserting on section output rather than the exit code is what keeps it
  deterministic across machines.

## Grilled

- **The fixture would have had a single markdown file, so `grep` prints no filename and the
  "names the offending file" assertion fails against the fixed script** → confirmed by running
  `grep` both ways. The fixture now carries a tracked, citation-free `docs/notes.md` in every
  condition.
- **An empty enumeration is a hang on GNU xargs, and two planned conditions constructed one** →
  the fixture now keeps a tracked markdown file and a tracked valid shell script present
  throughout, so neither enumeration is ever empty. Promoted to a stated decision above, because it
  is the kind of constraint a later edit silently removes.
- **A scratch copy of `verify.sh` inside the repo turns the sweep red on itself** → step 2 and
  step 4 both now say the copy lives outside the repository, and why.
- **The exclusion story credited `.git/info/exclude`, but the tracked `.gitignore` is what survives
  a fresh checkout** → corrected in the contract, in the helper's comment, and in the test, which
  now asserts both mechanisms.
- **A `human_only` acceptance criterion cannot be satisfied by an unattended run** → dropped in
  favour of the assertion that already covers it; the PR-body demonstration is now described as a
  courtesy to the reader rather than as evidence.
- **Nothing asserted the three syntax-side sites, and the stated reason for skipping them applied to
  only one of the three** → condition A now writes an untracked script with a syntax error and
  asserts `bash -n` catches it.
- **The gate's result becomes a function of untracked junk in the developer's tree, and the plan
  forbade excluding it** → accepted deliberately rather than designed around: the escape hatch is
  the ordinary git one, and narrowing the enumeration to dodge this would restore the blindness the
  change removes. Recorded as a limit in the contract and, per house style, documented in
  CONTRIBUTING where a contributor will hit it. This is the one finding that is a cost rather than
  a defect.
- **The cost of running all of `verify.sh` twice inside a fixture** → left as designed, but now
  named in the test strategy rather than discovered by the next person.
- **The no-recursion property is load-bearing and undocumented** → a comment in the new case.
- **Duplicate and deleted index entries** → checked and left alone. `--cached` is already the
  default, so `--others` introduces neither; both behaviours are pre-existing.
