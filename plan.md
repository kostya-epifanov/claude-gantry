# plan.md — integrate six parallel lanes as 0.4.0

Six branches, each green on its own. The work is not the merging — `git` does most of that — it is
finding the places where two lanes agreed with `git` and disagreed with each other.

## The one decision worth stating up front

**Where the integration's contract ends.** A merge resolution is not a licence to fix things. Three
of the six lanes recorded `scripts/verify.sh`'s unguarded `mktemp -d` in their handovers and all
three deferred it, correctly, as outside their own contracts. But "outside every lane's contract"
is not the same as "outside this one": the integration's contract is the release, and the release
would otherwise ship a gate that runs `rm -f /task.md` and `git init` in the user's repository the
first time `mktemp` fails.

So the rule for this branch is: **fix what the release cannot honestly ship, and nothing else.**
Two things met that bar and each is a separate, revertable commit —

1. the `mktemp -d` guard, and
2. `gantry-explorer`'s markdown line-number citations, which lane C's own change turns from a CI
   failure after the push into a local gate failure that blocks the Stop hook mid-run.

Nine other findings stay in `handover.md`, untouched.

## Steps

### 1. Merge the six, one merge commit each, in order of blast radius

`F → C → D → A → B → E`, smallest conflict surface first, so that each conflict is read against a
tree that already makes sense. One merge commit per lane, never a squash: the provenance is what
lets a reviewer read a lane's own pull request beside this one.

`plan.md` and `task.md` conflict on every merge, because every lane rewrote them. They are
single-run artifacts, not deliverables — resolve them to whatever is in the tree and write this
task's own pair at the end.

`handover.md` conflicts on four of the six. `skills/handover/SKILL.md` already settles how:
*"`HANDOVER:present` → read it and add to it. Never overwrite."* Accumulate the four, merge
duplicates at the end.

### 2. Resolve `lib/detect_stage.sh` by hand

The only source file two lanes rewrote. B adds `task_is_inherited()` and renames the `HOOK:` values;
E adds `human_only_state()` and a `HUMAN_ONLY:` line. The additions are independent — different
functions, different output lines — so the resolution is B's file with E's function and echo spliced
in at their documented positions, not a choice between them. Confirm by running the script and
seeing all three of `TASK:`, `HUMAN_ONLY:` and `HOOK:conditions-*` in one output.

### 3. Resolve the prose both lanes rewrote

`skills/implement/SKILL.md`'s report section is where B's honest `HOOK:` wording and D's coverage
paragraph land on the same lines. Take B's wording — it is the one that stopped overclaiming — and
keep D's paragraph beneath it. `docs/ARCHITECTURE.md`'s `lib/` tree gains three scripts from two
lanes and the count goes to five; the paragraph that says "exactly like the two above" no longer
has two above it.

### 4. Find the conflicts `git` could not see

This is the step that justifies the branch. Both were found by reading what each lane documented
against what another lane's script accepts:

- **D documents a `coverage` object on the `gate` event.** A's `journal_append.sh` permits
  `result exit attempt check artifact` on that event and exits 2 on anything else. Add
  `--coverage-verdict`, `--coverage-changed`, `--coverage-covered` and a repeatable
  `--coverage-root`; all-or-nothing, the verdict drawn from `gate_coverage.sh`'s six words, a root
  refused under the three verdicts that have none. `heuristic` is not a flag — always `true`, and
  `--coverage-heuristic` refused, on the same reasoning as `--ts`.
- **E documents a `disclosure` event.** A's script whitelists five. Add it as the sixth, with
  `--kind` deliberately unenumerated to match `escalation`'s `--reason` — both are documented as
  the place a new value goes — and `--pr` null rather than absent under `--no-pr`.

Then document both invocations under `skills/auto-unattended/`, because A's case *runs* every
command documented there. That check is what would have caught either of these at the moment the
second lane wrote its docs, and wiring the new commands into it is what stops the next pair.

### 5. The two fixes from the decision above

Guard `mktemp -d` with `exit 2`, not `exit 1`: this is *the gate could not run*, not *the gate found
a defect*. Change `gantry-explorer` to cite markdown by path alone — non-markdown paths keep their
line numbers, since the check is `\.md:[0-9]+` — and say the same thing in `skills/plan` step 4,
because the explorer is not the only thing whose output reaches *Affected areas*.

### 6. Release

`plugin.json` to `0.4.0`. `CHANGELOG.md`'s four concatenated `## Unreleased` blocks become one
`## 0.4.0` with single *Added* / *Fixed* / *Changed* sections — which means writing the entries for
lanes D and F, neither of which wrote one, and for the four integration changes above.

Consolidate `handover.md`: one heading per lane, findings demoted a level, and the two sections
step 5 closed removed — a handover records deferred work, and work that got done is recorded in the
changelog instead.

### 7. Gate

`bash scripts/verify.sh` must exit 0, which runs `bash tests/run.sh` and everything else CI runs.
Run it **unsandboxed**: `mktemp -d` fails under this session's sandbox, and after step 5 that is
now an honest `exit 2` rather than twenty spurious failures — which is the fix working, not the
gate breaking.

## What this plan does not do

Merge the six pull requests, touch the board, or close any of the nine findings still in
`handover.md`. See *Out of scope* in `task.md`.
