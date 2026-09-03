# plan.md — integrate PR #13 and PR #12 as 0.4.1

Two branches, each green on its own. As with 0.4.0, the work is not the merging — `git` does most
of that — it is the places where both branches agreed with `git` and disagreed with each other.

## The one decision worth stating up front

**Merge order, and why it is not arbitrary.** #12 is a rename: broad, shallow, mechanical, and
verifiable by counting tokens. #13 is a semantic change to two skills: narrow, deep, and verifiable
only by reading. Merging the semantic change first and the rename second means every conflict the
second merge raises is a rename conflict — resolvable by applying the rename to the new text, and
checkable afterwards by the same census #12 used on its own branch. The reverse order would have
put prose disagreements in the second merge, where they are hardest to see.

**Where the integration's contract ends.** A merge resolution is not a licence to fix things. One
thing met the bar: `.claude-plugin/plugin.json`'s description lists the phase skills as
`plan, grill, implement, review, ship`, and after #12 there is no skill called `grill`. #12 did not
touch the file — it had no reason to, the version bump lives on the other branch — so the drift
exists only in the merged tree, which makes it this branch's to fix. It is a separate, revertable
commit, and it is called out in `task.md`'s `human_only` because the manifest description is the
plugin's trigger surface and is paid in every session.

Nothing else. Both branches' deferrals stay in `handover.md`, untouched.

## Steps

1. **Branch `integration/v0.4.1-batch` off `master`.** Both PRs have `master` as their merge base,
   so neither has drifted.

2. **Merge #13 (`feat/v0.4.1`) with `--no-ff`.** Clean — merge base is `master`, and nothing else
   has landed since. One merge commit, so the three commits underneath stay legible.

3. **Merge #12 (`refactor/rename-grill-to-plan-grill`) with `--no-ff`.** Four conflicts, in
   descending order of how much judgement each needs:

   - `skills/auto/references/orchestration.md` — **the real one.** Both sides rewrote the line
     naming the semi-auto chain. Resolution carries both edits:
     `plan → plan-grill → implement → review --fix`.
   - `CHANGELOG.md` — #13 opened `## 0.4.1`; #12 wrote `## Unreleased`. Both ship in one release,
     so #12's entry moves into `## 0.4.1` under *Changed*, and the preamble gains a paragraph
     saying the release carries two breaking changes and naming where they met.
   - `task.md`, `plan.md` — each branch's own contract, and neither is the integration's. Replaced
     wholesale by this one, as the 0.4.0 integration did.

4. **Census the tree for silent loss.** The nine files both branches edited merged clean, which is
   exactly the condition under which a change disappears without a marker. Three sweeps:

   - `/gantry:grill` and `skills/grill/` appear nowhere → #12 survived #13.
   - `--reviewed` appears nowhere, and `skills/ship/SKILL.md` carries no `/code-review` invocation
     → #13 survived #12. Both are already assertions inside `scripts/verify.sh`, added by #13, so
     this sweep is the gate rather than a one-off command.
   - The phase-vocabulary tallies (`grilled`, `PHASE=grill`, `--phase grill`) match `master` → the
     asymmetry #12 chose deliberately was not "tidied" by the merge.

5. **Fix the manifest description.** One word, its own commit.

6. **Run `bash scripts/verify.sh`.** It is the gate and it runs `tests/run.sh`. Red stops the ship.

7. **Merge to `master` with one merge commit**, message naming both PRs.

## What this plan does not claim

The edited skills did not execute, and could not have: Claude Code loads `skills/` and `agents/`
from the *installed* plugin, not from this worktree. Every claim about what `ship` or `plan-grill`
does at runtime rests on reading the prose — the same limit both source runs recorded. What did
execute is `scripts/verify.sh`, from this worktree, including the two sweeps #13 added.
