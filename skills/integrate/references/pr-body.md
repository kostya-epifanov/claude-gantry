# The integration pull request

Detail behind stages 8 and 9 of `gantry:integrate`: what the body says, where each part comes
from, and the two things about merging it that are not obvious.

## What a reviewer is actually being asked

Not "is this diff good" — N reviewers already looked at the parts. The question is **what happened
when the parts met**: which conflicts were resolved and on what grounds, what had to be fixed
because two PRs disagreed, and what the combined tree proved. The body is built around that.

Everything in it comes from something durable: the merge commits and fix commits in git, the
skipped section of `task.md`, and the source PRs' own bodies. Nothing is composed from memory of the
run.

## Not hard-wrapped

GitHub renders a pull request body in **comment** mode, where a single newline inside a paragraph
becomes a `<br>`. Write each paragraph, each list item and each table row on **one line** however
long it runs. `scripts/check_pr_body.sh` decides this rather than judgement — the skill pipes the
composed file through it before `gh pr create`, and fixes what it names.

## The sections, in order

**Title.** `integrate: <n> PRs into <base> (#21, #23, #24)` or similar — the numbers belong in it,
because that is what people search for.

**An opening line.** What this is: N pull requests merged one at a time into a branch cut from
`<base>`, with the repo's checks run after every merge.

**`## Included`** — one table row per PR: number and title, its merge commit sha, whether it
conflicted (y/n), the gate result after it, and its own CI class at the time it was taken
(`passing`, `pending`, `none`). That last column is a disclosure, not decoration: `none` means that
PR's own checks never ran, and the gate run on this branch is the only check its code has had.

**`## Skipped`** — one line per PR left out, with the reason exactly as the run recorded it:
changes requested, a blocking label, red CI, conflicts with the base, a stacked parent that was not
selected, or a gate that stayed red after its merge. A PR with no reason beside it is a PR whose
author will ask why, and the answer will not be in anyone's memory by then.

**`## Conflict resolutions`** — one entry per conflicted file: the file, the two PRs, what each was
trying to do, and what the resolution kept. This is the section the reviewer cannot get from the
diff, and it is copied from the merge commit messages rather than rewritten.

**`## Fixes made during integration`** — each `integrate: fix` commit, and why the combination
needed it. Skip the heading when there were none.

**`## Not proven by this run`** — the exact heading, because its absence is meant to be
information. It carries every source PR's own `## Not proven by this run` items, attributed to the
PR they came from, plus anything this run could not prove: a `NO-GATES` override, a PR whose CI
never ran, a resolution nobody could check mechanically.

**`## Deliberately not done`** — every source PR's `## Deliberately not done` items, **with
duplicates removed**. Two PRs deferring the same thing is one deferral; listing it twice makes the
section look longer than the work left. Add anything this run deferred, including findings the
review handed back to a source PR's author through `handover.md`.

**`## How to merge this`** — the two facts below, in the body and not only in the report.

## How to merge it, and why it matters

**Merge it with a merge commit.** Then every source PR's head becomes reachable from the base, and
GitHub marks those PRs merged on its own — drafts included. This repository has seen it twice:
integration PRs #11 and #4 landed as merge commits, and the source PRs flipped to merged within
seconds, each showing the per-PR merge commit from the integration branch as its merge commit.

**A squash or a rebase breaks that.** Both rewrite the commits, so no source head ever reaches the
base, and every source PR stays open with its work already in. If that happens, the source PRs have
to be closed by hand, and their branches are then the only place their history survives.

**A stacked child may stay open anyway.** Its base branch is its parent's branch, not the
repository's base, and merging this PR never updates that branch — so the head-reaches-base rule
does not apply to it. Say so for each stacked PR in the queue. This one is unverified here: it
follows from how GitHub decides the merged state, not from anything this repository has observed.

## The comment on each source PR

After the PR is open, one comment per **newly** included PR, and never anything else — no push, no
close, no edit of its branch. Short, and enough to act on:

> Included in the integration PR <url>, merged as <sha>. This branch was not modified. If that PR
> is merged with a merge commit, GitHub will mark this one merged automatically.

A re-run does not comment again on a PR it has already commented on.
