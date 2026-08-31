# Plan — journal via a shim, and an idempotent exclude write

Contract: `task.md` (`2026-08-30-journal-append-helper`). Steps 1–2 are the deliverable, 3 proves
it, 4–6 make the documentation match, 7 is the gate. Revised after grilling; see **Grilled** at
the end for what changed and why.

## 1. `lib/journal_append.sh` — argv in, one JSON line out

New executable script. Header comment carries the contract in the style `run_gates.sh` uses: what
it is for, why the timestamp is not a parameter, and that `jq` is required.

**Interface.** `--task` and `--event` are required. The flag-to-key mapping is explicit, because
it is *not* uniform pluralisation — `escalation` carries **`detail`**, singular:

| Kind | Flags | Key |
|---|---|---|
| string | `--from --to --mode --phase --result --summary --stage --question --answer --reason --status` | same name |
| number | `--exit --attempt` | same name |
| repeatable | `--agent` / `--artifact` / `--check` | `agents` / `artifacts` / `checks` |
| repeatable | `--detail` | **`detail`** |
| output | `--file <path>` | default: `journal.jsonl` at `git rev-parse --show-toplevel` |

**Shape enforcement.** The script validates per event, so a malformed line cannot be written:

| event | required | permitted |
|---|---|---|
| `stage` | `--to` | `--from --to --mode` |
| `phase` | `--phase --result` | `--phase --result --summary --agent --artifact` |
| `gate` | `--result --exit` | `--result --exit --attempt --check --artifact` |
| `decision` | `--stage --question --answer` | those three |
| `escalation` | `--stage --reason --status` | those three, `--detail` |

A flag outside its event's column is exit 2; a missing required field is exit 2. Without this,
"emitted with the fields its shape specifies" is only true of the exact calls the test makes.

**Behaviour that has to be exactly right:**

- `ts` is always `date -u +%FT%TZ` taken inside the script. An explicit `--ts` is exit 2 with a
  message saying why — silently ignoring it would leave the caller believing it took effect.
- `--event` is checked against the five documented values; an unknown one is exit 2, so a typo
  cannot quietly produce an unqueryable line. This makes the script a second edit site when the
  schema grows, which step 4 writes into the *Extending* section.
- Field order is `ts, task, event` then the shape's own fields, matching the documented examples.
- A `stage` event with no `--from` emits `"from":null`.
- `--exit` and `--attempt` are validated as integers, then passed with `--argjson` so they land as
  JSON numbers. Validating first means a bad value is a usage error, not a jq parse error.
- Arrays accumulate one element at a time: `jq -nc --argjson acc "$acc" --arg v "$v" '$acc+[$v]'`,
  seeded `[]`. Exact for quotes and newlines, and it needs only jq 1.4 features. An absent
  repeatable flag still emits `[]` for `agents` — the shape documents `[]` as meaningful.
- **Every array expansion is count-guarded.** On bash 3.2 `"${arr[@]}"` on an empty array under
  `set -u` is a fatal unbound-variable error — confirmed by running it — which would kill exactly
  the `agents: []` case.
- **jq's exit status is checked before the append.** Otherwise a jq failure yields an empty
  capture and the `printf` still fires, writing a blank line the orchestrator believes is an
  event. A jq failure is exit 2 and appends nothing.
- Exactly one `printf '%s\n' … >>`. No rewrite path exists in the script, which is how
  append-only is guaranteed rather than asserted.
- Missing `jq`: exit 2 naming the dependency.
- SC2155: declare `local` and assign on separate lines, as `run_gates.sh` already does.

## 2. `lib/ensure_excluded.sh` — idempotent, race-free exclusion

New executable script. Takes one or more patterns and guarantees each appears exactly once in the
exclude file git actually reads.

- Target resolved with `git rev-parse --path-format=absolute --git-path info/exclude`, never a
  constructed path. From inside a linked worktree this correctly yields the *main* repo's file;
  the per-worktree `info/exclude` is not read by git, which is why the naive fix fails.
- `--file <path>` overrides the target, so the case can point at a fixture and never touch the
  developer's real file.
- Mutual exclusion via `mkdir "$target.lock"` — atomic on every POSIX filesystem, and present
  where `flock` is not. Released via a **single-quoted** `trap` (SC2064).
- **Stale-lock breaking.** A lane killed mid-write leaves the directory forever, and without a
  stale check every later run burns its retry budget and takes the unlocked path — so under
  exactly the conditions the lock exists for, all lanes would proceed unlocked at once and the
  double-append returns. After the bounded wait, a lock older than a threshold is removed and
  acquisition retried once; only then does it proceed unlocked with a warning on stderr. A
  headless run must not hang.
- Idempotence is an exact whole-line match, so a pattern that is a substring of another entry is
  not mistaken for present.
- **It also collapses duplicates already present** for the patterns it manages, so a file a
  previous racing writer corrupted is repaired rather than preserved. Unrelated lines are left
  byte-for-byte as found, and their order is preserved.
- Creates the parent directory and the file when absent. Exits 0 when everything was already
  present, reporting what it added.

## 3. `tests/cases/journal_append.sh`

One standalone case, auto-discovered by `tests/run.sh`. Sources `tests/lib.sh` for the assertions
but **adds nothing to it** — script paths and a small local runner are defined in the case, so it
cannot conflict with a parallel lane editing that file. It covers both scripts, as the contract
asks.

1. A `stage` append writes exactly one line; `jq -e .` accepts it; `from`/`to` survive.
2. `--from` omitted yields `from == null` — a JSON null, not the string `"null"`.
3. **Timestamp, without parsing a date.** Take `date -u +%FT%TZ` before and after the call and
   assert `before <= ts <= after` as string comparisons. ISO-8601 UTC at second precision sorts
   lexicographically in chronological order, so this needs no `date -d` (GNU) or `date -j -f`
   (BSD) — which are mutually exclusive and would fail deterministically for a developer outside
   UTC, or silently skip if written defensively.
4. `--ts` is refused with exit 2 and nothing is appended.
5. A `--summary` holding `he said "no"` and an embedded newline returns byte-identical through
   `jq -r .summary`.
6. Append-only: a second call leaves two lines and the first is unchanged.
7. `gate` emits `exit` and `attempt` as numbers (`jq -e '.exit|type=="number"'`).
8. `phase` with no `--agent` emits `agents: []`; with two, order is preserved.
9. `escalation` carries `detail` — the singular key — as an array of the given strings.
10. Exit 2 for: unknown `--event`, missing `--task`, a non-integer `--exit`, a flag that does not
    belong to the event, and an event missing a required field.
11. **Default path is the worktree root.** Build a repo, add a linked worktree with the existing
    `mkworktree` helper, invoke from inside it with no `--file`, and assert the line landed in the
    worktree's `journal.jsonl` and that the main checkout's is absent. This is the
    `hook_worktree_root` defect class, and it is invisible without an assertion.
12. `ensure_excluded.sh` twice against a fixture: exactly one copy of each pattern; a pattern that
    is a substring of an existing entry is still added; a fixture seeded with pre-existing
    duplicates ends with one copy of each.
13. **Concurrency.** N invocations launched in the background against one fixture, then `wait`;
    exactly one copy of each pattern. Two sequential runs cannot fail a lock that never locks.
14. **The docs match the script.** Extract every `journal_append.sh` invocation from the two
    markdown files and assert each flag is one the script accepts. A wrong flag in the docs
    otherwise ships green and fails only in a headless run — reproducing the very failure this
    task removes. This lives here rather than in `verify.sh`, which a parallel lane owns.
15. **Guard:** checksum the repo's real `.git/info/exclude` at the start and end of the case and
    assert it is unchanged, so a forgotten `--file` cannot corrupt the file under repair.

If `jq` is missing the case fails loudly rather than skipping — a silently skipped case is the
false green `tests/lib.sh`'s header warns about.

## 4. `references/journal.md`

- Replace the `printf "$(jq -nc …)"` idiom with the helper call, one example per shape so a caller
  never guesses a flag name.
- Say why it exists: a worktree-isolated session refuses command substitution and compound
  commands in the caller's argv, and the observed failure mode was invented timestamps.
- **Amend the no-writer-engine paragraph in place.** Keep the rule; state that an argv-to-JSON
  shim of this size is not what it refuses, and name `run_gates.sh` and `detect_stage.sh` as the
  precedent. Without this the next reader deletes the script as a violation.
- Keep the line that any producer emitting one JSON object per line is conformant — the helper is
  the convenient path, not a new requirement. *Not committed* is unchanged.
- *Extending*: a new `event` value now means editing the script's whitelist and its shape table.
- **State the rendering rule for runtime values.** Each documented command is executed in a fresh
  shell, so a documented `--exit "$RC"` would expand to empty and be refused. The docs show
  `<exit-code>`-style placeholders and say plainly: substitute the literal value you observed.
  This is the same discipline the timestamp fix enforces, applied to the gate's exit code.

## 5. `skills/auto-unattended/SKILL.md`

Every journal instruction in the body is prose today; each gets the concrete command, so stages
1–7 all show the same flat, substitution-free shape.

- **Stage 0's roster preflight is rewritten too.** It is `ROOT="$(git rev-parse --show-toplevel)"`
  plus a brace-expansion `ls` — itself a shape the guard refuses, and it alone would fail the
  contract's "no `$(` anywhere in this file" criterion. A lane hitting a refusal at stage 0 is the
  same defect this change exists to remove.
- Stage 1: the exclusion block becomes the `ensure_excluded.sh` call; the first `stage` event gets
  its command.
- Stages 2–3: the `phase` events and the `escalation` event. Stage 4: the `gate` event with
  `--attempt`. Stages 5–6: review's `phase` event and the final `stage` event. Stage 7 reports
  rather than journals and is unchanged.

Body stays under 500 lines (house style); it is ~200 now and the commands are short.

## 6. The other writer, and the docs that count the files

- **`skills/worktree/SKILL.md`** step 7 appends `**/.claude/worktrees/` to the same shared file
  with an unguarded `check-ignore || echo >>`, during worktree creation — the most concurrent
  moment of a six-lane batch, and itself a compound the guard refuses. It adopts the same call.
  Fixing only the orchestrator would ship a race-free helper beside the race.
- **`docs/ARCHITECTURE.md`** counts `lib/`'s scripts and names them; two additions make the count
  and the surrounding sentence wrong.
- **`references/delegation.md`** says the journal has "four event shapes"; there are five. It is a
  one-word correction in a file already in the blast radius — cheaper to fix than to hand over.
- **`CHANGELOG.md`** gets an entry, as every recent change here does.

## 7. Gate

`git add` the new files **first** — `verify.sh` enumerates with `git ls-files`, so an untracked
script gets a green run whose shellcheck sweep never saw it. Then `bash scripts/verify.sh`, which
runs `tests/run.sh` inside itself. Both new scripts must be `shellcheck -S warning` and `bash -n`
clean, and every relative link in the new markdown must resolve.

*Check for criterion 8:* `grep -nE '\$\(|<<|\| *while'` over both markdown files returns nothing.

## Test strategy

Both new scripts get assertions because both carry a guarantee expressible as one — a single line
of valid JSON with a self-generated timestamp landing in the right file, and exactly one copy of
each exclusion under concurrency. That is the standard `run_gates.sh` and the readiness hook are
held to.

The documentation edits are covered three ways: the grep in step 7, the link check the gate runs,
and assertion 14, which is the only one that catches a doc drifting from the script's real flags.

What cannot be tested here is that the harness guard accepts the new call shape — that depends on
the harness, not the repo. This run exercises it directly, so the run's own `journal.jsonl` is the
evidence, and the pull request says so rather than implying the suite covers it.

## Grilled

A fresh critic read `task.md` and `plan.md` cold and returned 5 blocking, 13 worth fixing, 7
noted. It found **no design fork**. Two of the blocking findings were unverifiable from a
read-only agent and were settled by running them before revising.

- **Stage 0 of the skill body also contains `$(`** → folded in as step 5's first bullet. The
  plan's own check would have failed on the first run, and the criterion is contract text.
- **`"${arr[@]}"` on an empty array is fatal under `set -u` on bash 3.2** → **confirmed by
  execution** (3.2.57: `arr[@]: unbound variable`). It would have killed the `agents: []` case.
  Count guards are now explicit in step 1.
- **`$ARGS.positional` is one flat list and cannot keep four arrays apart**, and `--args` with
  `--` behaves differently across jq versions — silently yielding `[]` rather than erroring →
  the mechanism was replaced with incremental accumulation, verified against the installed jq.
  This removes a version dependency instead of betting on one.
- **The default journal path is cwd-sensitive**, so a call made from the launch checkout writes
  every lane's events into the main repo's journal → assertion 11 now proves it from a real
  linked worktree. This is the `hook_worktree_root` defect class, which the suite already exists
  to catch once.
- **A failed jq would append a blank line and exit 0** → jq's status is checked before the append.
- **The 5s timestamp assertion had no portable clock conversion** — GNU and BSD `date` parsing are
  mutually exclusive, and BSD parses local time, so it would fail by a developer's UTC offset →
  replaced with a lexicographic before/after comparison that needs no date parsing at all.
- **The `mkdir` lock could go stale forever**, degrading to "everyone proceeds unlocked" under
  precisely the conditions it exists for → stale-breaking added in step 2.
- **Two sequential runs cannot fail a lock that never locks** → assertion 13 launches real
  concurrent writers.
- **An already-corrupted exclude file would stay corrupted** → the script now collapses existing
  duplicates of the patterns it manages, and the contract says so.
- **`skills/worktree` writes the same file unguarded** → adopted in step 6. Fixing only the
  orchestrator would not close the race, which is the stated goal.
- **`--detail` is singular** while the sibling arrays are plural → the mapping is now an explicit
  table rather than an inferred rule.
- **No per-shape validation made criterion 5 unfalsifiable** → the shape table in step 1 is now
  enforced, and the contract gained a criterion for it.
- **Runtime values in documented commands** would expand to empty in a fresh shell → step 4 fixes
  a placeholder convention. This is the timestamp lesson applied to the gate's exit code.
- **Named shellcheck warnings** (SC2064, SC2155) and **`verify.sh` linting only tracked files** →
  step 7 stages before gating; step 1 and 2 copy the existing scripts' workarounds.
- **The case could mutate the real shared exclude file** → assertion 15 checksums it.
- **Nothing checked the docs against the script's real flags** → assertion 14, placed in the case
  rather than `verify.sh` because a parallel lane owns that file.
- **`ARCHITECTURE.md`'s script count, the CHANGELOG entry, and delegation's "four shapes"** →
  step 6.

Consciously left:

- **One case file covers both scripts**, so `bash tests/run.sh ensure_excluded` matches nothing
  and an exclusion regression reports under `journal_append`. The suite's convention is one case
  per concern, but the contract names this file explicitly; following the instruction beats
  following the convention here.
- **`journal_append.sh` has one consumer**, which the architecture doc says is not what `lib/` is
  for. The contract pins the path, so this is the contract's call. Step 6's adoption of
  `ensure_excluded.sh` by `skills/worktree` gives that one two consumers.
- **"Generated inside the script" is not observable from outside** — only "close to now" is, which
  a caller-supplied `now` also satisfies. The real guarantee is the `--ts` refusal, and the
  contract now says so rather than counting the timing assertion as proof.
