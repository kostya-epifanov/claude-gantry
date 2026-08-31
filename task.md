---
id: 2026-08-30-journal-append-helper
title: Journal via a shim, and make the exclude write idempotent
project: claude-gantry
branch: fix/journal-append-helper
mode: unattended          # semi-auto | auto | unattended — which mode is driving
status: shipped           # planning | planned | grilled | implementing | implemented |
                          # reviewed | shipped | blocked. The readiness hook arms on
                          # exactly `implementing` and ignores every other value.
---

## Context & goal

`references/journal.md` documents the journal append as a `printf` of a `$(jq -nc --arg ts
"$(date -u +%FT%TZ)" ...)` command substitution. A worktree-isolated session refuses to run
that: the harness guard cannot verify that a compound command with substitutions stays inside
the worktree, so it declines the call outright. Five of six lanes in the last parallel batch hit
it.

The cost is not the retries. One lane worked around the refusal by calling `date -u` once and
hand-writing the remaining timestamps as estimates. Its event ordering is accurate and its clock
is fiction, and nothing downstream can tell the difference — the journal's whole value is being
evidence, and an invented `ts` silently destroys that. The fix is to move the substitution
*inside* a script, where it is ordinary shell, so the orchestrator's own argv stays flat.

The same stage has a second defect. Stage 1 appends `journal.jsonl` and `.claude/artifacts/` to
the main repo's `.git/info/exclude`, which every linked worktree shares. Six parallel lanes
interleave their read-then-append and one lane observed double-appended entries. A linked
worktree does have its own git dir, but git maps `info/` into the *common* dir, so a
per-worktree `info/exclude` is a file git never reads — verified by command, see Affected areas.
The write therefore has to stay on the shared file and become idempotent and mutually exclusive
instead.

## Acceptance criteria

- [ ] `bash lib/journal_append.sh --task T --event stage --from plan --to implement` appends
      exactly one line to `journal.jsonl` at the worktree root, and `jq -e .` accepts it.
- [ ] A `--summary` value containing a double quote and a newline round-trips byte-for-byte
      through `jq -r`.
- [ ] `ts` is generated inside the script: an explicit `--ts` is refused with exit 2, and the
      emitted `ts` sorts at or after a timestamp taken immediately before the call and at or
      before one taken immediately after. (Both halves are needed — "close to now" alone is also
      true of a caller-supplied `now`, so the refusal is what carries the guarantee.)
- [ ] Each of the five documented events — `stage`, `phase`, `gate`, `decision`, `escalation` —
      is emitted with the fields its shape specifies; `exit` and `attempt` are JSON numbers, and
      a `stage` event with no `--from` emits `"from":null`.
- [ ] A flag that does not belong to the event given is refused with exit 2, and an event missing
      a field its shape requires is refused with exit 2. The shape is enforced, not merely
      transcribed.
- [ ] A second invocation appends rather than rewrites: the file has two lines and the first is
      byte-identical to what it was.
- [ ] The default journal path resolves to the root of the worktree the call is made from, not
      the main checkout — asserted from a real linked worktree.
- [ ] `bash lib/ensure_excluded.sh <pattern>...` run twice leaves exactly one copy of each
      pattern in the target exclude file, and collapses duplicates a previous racing writer
      already left there.
- [ ] Concurrent invocations do not double-append: N racing writers against one file leave
      exactly one copy of each pattern.
- [ ] Every `journal_append.sh` invocation shown in the documentation uses only flags the script
      actually accepts.
- [ ] No idiom in `references/journal.md` or the `auto-unattended` skill body contains `$(`, a
      heredoc, or a pipe into a `while` loop.
- [ ] `references/journal.md` states, where the no-writer-engine rule is stated, why an
      argv-to-JSON shim is not the writer engine that rule refuses.
- [ ] `bash tests/run.sh` and `bash scripts/verify.sh` are green.

## How to verify

```
bash tests/run.sh journal_append     # the new case on its own
bash tests/run.sh                    # the whole suite, nothing regressed
bash scripts/verify.sh               # shellcheck, link resolution, secret scan, suite
```

The new case is the evidence for every behavioural criterion above. Two things it does not
cover, checked by reading instead:

- That the rewritten idioms are free of `$(`, heredocs, and `while`-pipes — a grep over the two
  markdown files, run during review.
- That the harness guard actually accepts the new call shape. Only a real worktree-isolated
  session can demonstrate that, and this run is one, so the run's own journal is the evidence.

## Out of scope

- No log framework, rotation, reader, or query tool. Two small scripts, nothing more.
- The event schema is unchanged. No new fields, no new event values.
- `journal.jsonl` stays uncommitted, and what gets excluded is unchanged — only *how* the
  exclusion is written changes. `.gitignore` is not touched.
- `lib/run_gates.sh` and `lib/detect_stage.sh` are not touched; parallel lanes own those.
- `tests/lib.sh` and `scripts/verify.sh` are not touched — parallel lanes own the latter, so the
  documentation-matches-the-script check lives in the test case instead.
- No general cleanup of the shared exclude file. `ensure_excluded.sh` de-duplicates only the
  patterns it was asked to ensure; unrelated entries are left exactly as found.

## Affected areas

- **`lib/journal_append.sh`** (new). The shim. Follows the shape `run_gates.sh` and
  `detect_stage.sh` already have: `#!/usr/bin/env bash`, `set -uo pipefail`, a header comment
  carrying the contract, exit 2 for usage errors, root resolved with `git rev-parse
  --show-toplevel`. The envelope is built by one `jq -nc` so escaping is jq's problem, not a
  hand-rolled quoter's. Repeatable flags (`--agent`, `--artifact`, `--check`, `--detail`)
  accumulate into JSON arrays one element at a time — `--argjson acc "$acc" --arg v "$v"
  '$acc + [$v]'` — which is exact for quotes and newlines and needs only jq 1.4 features. The
  `--args`/`$ARGS.positional` form was rejected: it is one flat list, so it cannot keep four
  arrays apart, and its interaction with `--` varies by jq version in a way that silently
  produces an empty array rather than an error.
- **`lib/ensure_excluded.sh`** (new). Idempotent, mutually exclusive append to the exclude file
  git actually reads. Locates it with `git rev-parse --git-path info/exclude` rather than
  assuming a path, and serialises concurrent lanes with an atomic `mkdir` lock — `flock` is not
  present on stock macOS, which the test suite explicitly targets.
- **`skills/auto-unattended/references/journal.md`**. The documented idiom, and the
  no-writer-engine paragraph that would otherwise read as a standing instruction to delete the
  new script.
- **`skills/auto-unattended/SKILL.md`**. Every journal call site is currently prose ("Journal a
  `phase` event"), so the change is to give each one the concrete command. Stage 1's exclusion
  block is a bare list of two patterns and becomes a call to the new script.
- **`skills/worktree/SKILL.md`**. Its step 7 writes `**/.claude/worktrees/` to the same shared
  file with an unguarded `check-ignore || echo >>`, during worktree creation — the most
  concurrent moment of a parallel batch. Leaving it would ship a race-free helper beside the
  race it exists to close, so it adopts the same call.
- **`docs/ARCHITECTURE.md`, `CHANGELOG.md`**. The architecture doc counts `lib/`'s scripts and
  names them; two additions make the count wrong. The changelog is where this repo files every
  change.
- **`tests/cases/journal_append.sh`** (new). Auto-discovered by `tests/run.sh` from `cases/*.sh`;
  no wiring.
- **Risks.** `scripts/verify.sh` lints only *tracked* `*.sh` (`git ls-files`), so the new scripts
  must be `git add`-ed before the gate is believed — an untracked script gets a green run that
  never linted it. It runs `shellcheck -S warning`, which fails on `trap "…$var…"` (SC2064) and
  `local x="$(…)"` (SC2155); the existing scripts already avoid both, so copy their shape.
  `tests/lib.sh` pins the suite to bash 3.2, where `"${arr[@]}"` on an *empty* array under
  `set -u` is a fatal unbound-variable error — confirmed by running it — so every array
  expansion needs a count guard. `scripts/secret-scan.sh` rejects a developer's absolute home
  path in any tracked file, so fixtures must build paths from `mktemp -d`. The suite runs with
  cwd at the repo root, so a case that omits `--file` would append to the developer's *real*
  shared exclude file. `jq` is already a hard dependency of `verify.sh`'s manifest checks, so
  requiring it adds nothing new — but the script must say so rather than fail obscurely.

## Open questions

None. The one genuine fork in the brief — per-worktree exclude file versus idempotent shared
append — was settled by measurement before planning began, not by judgement:

- [x] Where do the exclusions go? Decided: the shared `.git/info/exclude`, made idempotent.
      `git rev-parse --path-format=absolute --git-path info/exclude`, run from inside this linked
      worktree, resolves to the *main* repo's file, and a probe entry written to
      `.git/worktrees/<name>/info/exclude` left its file still reported untracked by `git
      status`. The brief's preferred option targets a path git does not read.
- [x] One script or two? Decided: two. The exclude fix needs a lock and a git-path lookup that
      have nothing to do with emitting JSON, and the brief requires it be reachable as a single
      command with no substitution in the caller's argv — which is what a script is for.
- [x] Does the shim violate "there is no writer engine"? Decided: no, and the change says so in
      the paragraph that states the rule. The rule refuses a log framework; `run_gates.sh` and
      `detect_stage.sh` are already argv-in, contract-out scripts of exactly this size.
