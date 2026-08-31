# Handover — fix/verify-sees-untracked-files

Deferred from *Make verify.sh enumerate untracked files, so the gate sees what the run just wrote*.
The change itself is complete and the gate is green; these are findings it did not absorb.

## The explorer still emits line-number citations, and now the gate catches them locally

**What it is.** `agents/gantry-explorer.md` instructs the explorer to return `path:line`
references, and `skills/plan/SKILL.md` step 3 tells the author to paste that summary into
`task.md`'s *Affected areas*. `task.md` is untracked when `implement` runs the gate, and this change
puts untracked markdown inside the citation check. So on any gantry-on-gantry run where `plan`
dispatches the explorer and the explorer cites a markdown file, `scripts/verify.sh` now goes red —
and because `.claude/gates.sh` execs `verify.sh`, the readiness hook blocks the Stop until the
author strips the numbers by hand.

**Why it was deferred.** It is a change to the *producer*, in two files this task's contract never
names — the task covers `scripts/verify.sh`'s enumeration and nothing about what the checks look
for. It also would not take effect for the next lane: a skill or agent edited in a worktree is not
the copy the running plugin loads, so the fix only lands on release.

**What was already established.** This is not a regression, and that matters for how urgently it is
treated. Before this change the same `task.md` passed locally and failed **CI** — a red pull
request, which is how the previous lane discovered it and stripped the citations by hand. The check
now fires minutes earlier, at the cheapest possible moment, which is the entire point of the ticket.
The rule itself is not in question either: line-number citations rot on the first edit, which is why
`verify.sh` has forbidden them since before this change. What is wrong is that one part of the
pipeline is documented to produce exactly what another part is documented to reject. The unattended
driver can recover on its own — the remedy is editing `task.md`, which it can do inside its two fix
attempts — so this degrades a run rather than deadlocking it.

**Next action.** In `agents/gantry-explorer.md`, change the instruction that citations carry a line
number to say that a markdown path must be cited by path alone. Non-markdown paths can keep their
line numbers: `verify.sh`'s check is `\.md:[0-9]+`, so `lib/run_gates.sh:40` was never at issue.
Then add one sentence to `skills/plan/SKILL.md` step 3 saying to strip trailing line numbers from
markdown paths when pasting into *Affected areas*, because the explorer is not the only thing whose
output lands there.

## `verify.sh` runs `rm` and `cp` against absolute paths when `mktemp -d` fails

**What it is.** In `scripts/verify.sh`'s `detect_stage.sh` fixture block, `fixdir="$(mktemp -d)"` is
unguarded. When `mktemp` fails, `$fixdir` is the empty string and the block goes on to run
`rm -f "$fixdir/task.md"` and `cp … "$fixdir/task.md"` — that is, against `/task.md` — and
`git init -q .` runs in the repository itself rather than in a fixture.

**Why it was deferred.** Pre-existing, unrelated to the enumeration change, and revealed by this
work only incidentally. Fixing a latent bug in a file because the diff happens to touch that file is
how a reviewable change stops being one.

**What was already established.** Observed directly, not theorised: running the gate inside this
session's sandbox made `mktemp -d` fail with `Operation not permitted`, and the transcript then
shows `error: could not lock config file …/.git/config` from the stray `git init`, followed by
around twenty `/task.md: Operation not permitted` lines and roughly a dozen spurious `FAIL`
assertions. Nothing was damaged, because the same sandbox denied the writes — on a machine where
those paths are writable it would not have been so tidy. A second lane on this repo independently
hit the same thing and confirmed the rule: run `verify.sh` unsandboxed, and do not change it to
accommodate the sandbox.

**Next action.** Add `[ -n "$fixdir" ] || { bad "could not create the fixture repo"; exit 2; }`
immediately after the `mktemp -d`, before the `trap` that would otherwise `rm -rf ""`.

## `scripts/secret-scan.sh` scans tracked files only, and the reasoning behind that is now partly stale

**What it is.** `secret-scan.sh` enumerates with a bare `git ls-files`, and its header justifies
this: "untracked scratch is not being published." For ordinary scratch that is right. It is not
right for the files a gantry run writes — `task.md`, `plan.md`, `handover.md` are untracked when the
gate runs and committed by `ship` minutes later, so a secret pasted into one of them is invisible to
the local publish gate and is caught only by CI, after the push. That is the same green-local
/red-CI shape this change closed in `verify.sh`.

**Why it was deferred.** The task's contract excludes it, and deliberately: unlike `verify.sh`'s
enumeration, this one is a written, reasoned decision rather than an oversight, and reversing it is
a judgement about the publish gate's scope rather than a bug fix.

**What was already established.** The risk of simply copying this change across is concrete and was
the reason for not doing it blind. `secret-scan.sh`'s S2 patterns include `/Users/[a-z0-9]` and
personal identifiers; the moment untracked files are in scope, any scratch file holding an absolute
home-directory path trips the publish gate. `verify.sh` could absorb its newly-visible files because
its checks are narrow; `secret-scan.sh`'s are deliberately broad, and broad patterns over
unreviewed scratch is a false-positive engine.

**Next action.** Decide the scope question first, because it determines whether there is any work at
all: should the publish gate cover what *this run is about to publish* (`task.md`, `plan.md`,
`handover.md`) rather than everything untracked? If yes, the narrow change is to add those three
paths explicitly to `files()` in `scripts/secret-scan.sh` rather than switching it to
`--others --exclude-standard`, which keeps the header's reasoning intact and closes the actual hole.
