# Changelog

## 0.4.0

**Six changes developed in parallel, merged as one release.** Each was planned, grilled,
implemented, reviewed and shipped in its own worktree against its own contract, and each opened its
own pull request; this version is those six resolved against each other. Two of them turned out to
disagree, and the conflicts were not textual — `git` merged both files cleanly. They are recorded
under *Changed* below, and finding them is the argument for integrating a batch deliberately rather
than merging six green branches in sequence.

The theme across the six is the same one 0.3.0 started: a claim the pipeline makes about itself has
to be established by something that can fail. A gate that never read the changed files, a detector
reporting a guarantee it could not see, a run whose own journal it could not write, sub-agents
asserting facts about an environment they never queried — each was true-sounding prose, and each is
now a value some script produces or refuses.

**Added**
- `lib/journal_append.sh` — the documented journal idiom was a `printf` of a command substitution
  wrapping `jq`, with a nested one supplying the timestamp. A worktree-isolated session refuses to
  run that: the harness cannot verify such a command stays inside the worktree, and five of six
  lanes in one parallel batch hit the refusal. The retries were not the damage — one lane worked
  around it by calling `date -u` once and hand-writing the rest of its timestamps as estimates,
  producing an accurate event ordering with a fictional clock that nothing downstream could
  detect. The substitution now lives inside a script, so the caller's argv stays flat, and `ts` is
  no longer a parameter: `--ts` is refused rather than ignored. The script validates each of the
  five event shapes, so a field the shape does not carry, or a required one left out, is exit 2
  instead of a malformed line.
- `lib/ensure_excluded.sh` — stage 1 excluded `journal.jsonl` and `.claude/artifacts/` with a
  `grep -q … || echo … >>` against `.git/info/exclude`. Git maps `info/` into the *common* git dir,
  so that file is shared by every linked worktree and there is no per-worktree copy to write
  instead — measured, not assumed: `git rev-parse --git-path info/exclude` from inside a linked
  worktree resolves to the main repository's file, and a pattern written to the per-worktree path
  leaves `git status` still reporting the file as untracked. Six lanes interleaving that read and
  write produced double-appended entries. The write is now locked, whole-line matched, and repairs
  duplicates an earlier writer left. `skills/worktree` adopts it too — fixing only the
  orchestrator would have left the same race in the most concurrent moment of a batch.
- `lib/gate_coverage.sh`, and a coverage transcript from `lib/run_gates.sh` — an answer to "did
  the gate read anything this change touched?". `run_gates.sh` now emits a `COVERAGE root=… check=…`
  line per check and one `== coverage roots=… ==` summary; `gate_coverage.sh` reads that transcript,
  compares the roots against the changed paths, and prints a verdict of `overlap` · `no-overlap` ·
  `undeclared` · `no-checks` · `no-changes` · `unknown`. `implement` runs it at step 5b and reports
  the verdict beside the exit code. A green gate that read none of the changed paths exits `0`
  exactly like one that proved something, and this is what makes the two distinguishable after the
  fact.

  It **reports and never refuses**: no exit code changes, nothing is blocked, and low overlap is not
  a failure. The comparison is a heuristic and says so in every place it is emitted — a root is the
  directory a check *ran in*, never the set of files it *read*, and it errs in both directions.
  Refusing on it would fire on every documentation-only change and needs an override design first;
  that refusal was in the ticket and is deliberately not in this release.

  Its motivating case is one gantry cannot reproduce on itself: this repo gates through a
  repo-owned `.claude/gates.sh`, whose roots the script cannot attribute, so gantry's own runs
  report `undeclared` — honestly, and without pretending to a measurement.
- `lib/detect_stage.sh` prints **`HUMAN_ONLY:present|none|absent`** — whether `task.md`'s
  `human_only` block, the acceptance criteria no automated gate can check, holds any entries. It
  was decorative before this: it appeared in the template, the worked example and this repo's own
  `task.md`, and no script parsed it, no skill read it and no journal event carried it. The signal
  is a printed fact rather than a prose instruction because four recorded runs read a clear prose
  rule to check that block and all four ignored it. A separate reader from `frontmatter_status()`,
  which stays byte-identical to the hook's copy; permissive in every case toward reporting
  `present`, since a missed disclosure is the failure and a spurious one costs a heading.
- A `disclosure` event in the unattended journal, with `kind` as its extension point, recording
  that a run shipped with unproven acceptance criteria or an unexercised plugin change. The driver
  copies it from ship's report rather than re-deriving it.
- `tests/cases/verify_untracked.sh` — the assertion that the above stays fixed. A fixture repo with
  an untracked `task.md` carrying a citation, an untracked script with a syntax error, and two
  copies of the citation in files excluded by the tracked `.gitignore` and by `.git/info/exclude`
  respectively. It asserts the first two are caught, the last two are not, and that removing the
  offenders returns both checks to clean. Negative-tested: three of its nine assertions fail
  against the pre-fix script, and the other six — the ones guarding an over-correction that would
  start sweeping the run's own journal and gate logs — pass either way.
- `tests/cases/journal_append.sh` — covers both scripts. The assertions that matter are that a
  caller cannot choose the timestamp, that a line lands in the worktree the call was made from
  rather than the main checkout, and that eight concurrent writers **each asking for a different
  pattern** all survive. The distinctness is the whole point: eight writers asking for the *same*
  pattern prove nothing, because each rewrites through a temp file and renames atomically, so no
  interleaving can leave a duplicate whether the lock works or not — that version of the assertion
  passed with the lock deleted. What the lock prevents is a lost update, and it is only visible
  when the writers want different things: measured at 4 of 8 patterns surviving without the lock
  and 8 of 8 with it. Every documented invocation of the helper is executed by the case, so a
  flag name in the docs cannot drift from the script and fail only in a headless run.
- `tests/cases/gate_coverage.sh` — the verdict table over a fixture repo: every verdict value,
  the run-artifact exclusion, and a transcript from a gate that died mid-run reported as `unknown`
  rather than as zero coverage.
- Six cases in `tests/cases/stage_phases.sh` covering `TASK:inherited` and each degradation, plus
  a clone fixture whose local base lags `origin` — the case that decides whether the feature fires
  in gantry's own worktree workflow at all, and the one every all-local fixture passes either way.
- `tests/cases/stage_human_only.sh` — fifteen assertions over the new line. The load-bearing one is
  a YAML block sequence at its key's own indentation, which the first draft of the parser reported
  as `none`: valid YAML, used by none of the three existing blocks, and silent in the one direction
  this must never fail in. Confirmed non-vacuous — deleting the new `echo` fails the case.

**Fixed**
- **`scripts/verify.sh` could not see the files a run had just written.** All six of its
  enumerations were a bare `git ls-files`, which lists tracked files only — so at gate time
  `task.md` and `plan.md` were invisible to the line-number-citation check, the forbidden-string
  sweep and the relative-link check. `implement` runs the gate; `ship` commits minutes later; CI
  then runs the identical script with those files tracked. Green locally, red in CI, on the
  pipeline's own artifacts — and not hypothetically: `plan` tells you to paste the explorer's
  output into *Affected areas*, and the explorer returns citations in exactly the form the citation
  check forbids. A lane in this repo hit it and stripped them by hand. The same hole covered a
  `lib/*.sh` written during `implement`, which was never parsed or shellchecked until after it was
  pushed. Every site now enumerates with `git ls-files --cached --others --exclude-standard`
  through one named helper, so a seventh site cannot be added without the flags.

  The change is a **no-op in CI**, where a fresh checkout has no untracked files at all. All of the
  new coverage is local, which is the asymmetry it set out to close.

  Two limits, both documented rather than designed around. A red local run no longer implies a red
  CI run — an untracked virtualenv or scratch directory is now inspected, and the remedy is to
  ignore the path, not to narrow the enumeration; this is written up in CONTRIBUTING where a
  contributor will meet it. And `scripts/secret-scan.sh` still enumerates tracked files only, on
  purpose: it is the publish gate, its header reasons about the choice explicitly, and widening it
  is a separate judgement with its own false-positive risk.
- **`scripts/verify.sh` ran `rm -f` and `cp` against `/task.md`, and `git init` in the repository
  itself, whenever `mktemp -d` failed.** `fixdir="$(mktemp -d)"` was unguarded, and every line of
  the `detect_stage.sh` fixture block then operated on the empty string. `cd ""` **succeeds** in
  bash, so the subshell kept the repository as its cwd; the assertions went on to rerun the detector
  against the repository's own `task.md`, which is a false green as readily as a false red, and the
  EXIT trap became `rm -rf ""`. Three of the six lanes hit it independently in one batch and all
  three deferred it as outside their contracts — correctly, and it is why it is fixed here instead.
  Nothing was damaged only because the sandbox that triggered it also denied the writes. The block
  now exits 2, *the gate could not run*, rather than exit 1, *the gate found a defect*.
- `skills/auto-unattended/SKILL.md` — every journal call site, and the stage 0 roster preflight,
  are now flat commands. The preflight was itself a shape the guard refuses, so a lane could fail
  before reaching the stage the journal fix was for.
- **`gantry:ship` now discloses what the run did not prove, before it opens the PR.** On
  `HUMAN_ONLY:present` the body carries a fixed `## Not proven by this run` heading with the
  entries verbatim, so the heading's *absence* is itself information. Under `--draft` the body
  states what draft status does not mean: unwatched, not unverified. These reach the report under
  `--no-pr` too, where there is no body to carry them.
- **Ship names the plugin version that actually executed** when the repo is a plugin and the diff
  touches `skills/`, `lib/`, `hooks/` or `agents/`. The harness loads skills from the *installed*
  plugin, so a change to them is not exercised by the run that makes it — a measured case shipped a
  PR whose headline feature was never once executed by the run that produced it, reported as
  success. Resolved from the installed-plugins registry, never guessed; an undeterminable version
  is disclosed as undeterminable. The disclosure distinguishes `skills/` and `agents/` (loaded by
  the harness, genuinely unexercised) from `lib/` and `hooks/` (run from the worktree by the repo's
  own suite), and is suppressed entirely when the plugin root and the repo are the same tree — the
  `--plugin-dir` shape, where the edits did execute.
- **Ship re-reads its own prose** before `gh pr create`: the title, the body, and the commit
  subject, which are the only text no phase reads. One rule — a claim about how something works
  either cites the file that establishes it or does not go in the body — because two false
  mechanism claims once reached a PR body and cost three commits and two rewrites to correct. The
  subject is additionally checked in the commit stage, the only point at which amending is free.
  `/gantry:review` is deliberately **not** extended to cover this, and the reason is recorded in
  `skills/ship/SKILL.md` so it is not "fixed" back: review runs against the diff, before ship has
  composed anything.
- **`gantry-explorer` was documented to produce exactly what `scripts/verify.sh` is documented to
  reject.** The explorer returns `path:line` citations, `skills/plan` tells the author to paste that
  summary into *Affected areas*, and the citation check fails any `.md:<line>` — which, now that the
  gate enumerates untracked files, fires on the still-uncommitted `task.md` at the next gate rather
  than in CI after the push. Two lanes in this batch hit the CI half and stripped the numbers by
  hand. Markdown paths are now cited by path alone; non-markdown paths keep their line numbers,
  since the check is `\.md:[0-9]+` and `lib/run_gates.sh:40` was never at issue. `skills/plan`
  carries the same instruction, because the explorer is not the only thing whose output lands there.

- **Sub-agents asserted facts about the environment they had never established.** An explorer
  reported "the `claude` CLI is absent" from a sandboxed `command -v`, and a critic told its caller
  which files it need not check. `agents/*.md` now require a claim about the environment to name
  what established it, and the requirement is phrased per role rather than uniformly: an explorer
  and a critic hold only `Read`, `Grep` and `Glob`, so they cite a *search* — the pattern and its
  scope, a glob, a file and a line range — while a reviewer, which also holds `Bash`, cites the
  command. Telling a read-only agent to "name the command that established it" invites exactly the
  fabricated provenance the rule exists to stop. A negative claim is additionally scoped to what was
  searched, and an explorer is explicitly barred from telling its caller what *not* to check: it
  reports what it found, and the caller decides what that means. Nothing enforces this, and
  `docs/METHOD.md` says so rather than implying an unenforced rule is a guarantee.

**Changed**

**`lib/detect_stage.sh`'s output contract.** Two of its lines now report what the script
can establish rather than what a reader might infer. Anything parsing this output needs updating.

- **`HOOK:armed|inert` is now `HOOK:conditions-met|conditions-unmet`.** The line is computed from
  `.claude/gates.sh` and `task.md`'s status alone — the hook's *firing conditions*. Whether the
  hook is **registered** is invisible to the script, so `armed`, which reads as "the gate is
  enforced on this run", was a claim it could not back. Renaming was chosen over detecting
  registration because that detection cannot be made reliable: the manifest lives in the plugin
  root while the detector resolves the repo root, gantry's own repository *is* the plugin source
  and carries `hooks/hooks.json` at its root, and even the right manifest would not say whether the
  plugin is enabled. A second overstatement is not an improvement on the first. Updated in
  `skills/auto/references/orchestration.md`, `skills/auto/SKILL.md`,
  `skills/auto-unattended/SKILL.md`, `skills/implement/SKILL.md`, `docs/SKILLS.md` and
  `tests/cases/stage_phases.sh`. The word stays where it describes the *hook* rather than the
  detector's claim about it — `hooks/readiness-gate.sh`, `README.md`, `docs/METHOD.md`.
- **`TASK:` gained a third value, `inherited`.** `task.md` is committed with every pull request, so
  a worktree freshly cut from the base branch is born holding the *previous, merged* contract. The
  detector reported `TASK:present STATUS:shipped`, and `skills/plan/SKILL.md` routed that to "a
  task is already under way — never clobber either file", which told every unattended run on a
  clean branch to revise a finished, unrelated contract. `inherited` is now established as a fact:
  `task.md` byte-identical to the copy at the merge-base with the base branch **and** carrying
  `status: shipped`. Every condition the script cannot establish — a detached `HEAD`, no resolvable
  base, no merge-base, no `task.md` at the merge-base, any git error — degrades to `present`,
  because reading a live task as inherited destroys work while reading an inherited task as present
  costs one supersede. `skills/plan/SKILL.md` routes it to a clean start;
  `skills/handover/SKILL.md` and `skills/auto-unattended/SKILL.md` were updated so the new value
  does not fall through their `present`-only branches.

  `PHASE:` and `NEXT:` are deliberately unchanged: an inherited task still resolves to `done`,
  since deriving the phase from the new value would change how `implement`, `review` and `ship`
  route. See `handover.md` on the branch.

**`skills/plan/SKILL.md` writes *Out of scope* after the code study.** It was written in
step 2 "before studying code", with the study in step 3 — but out-of-scope is the section that most
needs code knowledge, since what a change touches is what tells you what it will not. It is also
load-bearing downstream, where `gantry:review` triages findings against it and `gantry:handover`
quotes it, so a guess there is read as a decision. A new step 4 now writes *Out of scope* and
*Affected areas* together from what the study found; later steps renumber. `docs/ARCHITECTURE.md`
and `docs/SKILLS.md` updated to match.

**`lib/journal_append.sh` carries what the other lanes journal.** Two of the six wrote
into the journal a shape the third had just made impossible, and both merged clean because neither
touched the other's file.

- The **`gate` event's `coverage` object** is now emitted through `--coverage-verdict`,
  `--coverage-changed`, `--coverage-covered` and a repeatable `--coverage-root`. The coverage lane
  documented that object and the journal lane, landing separately, wrote a validator that permits
  only the fields its shape names — so the documented gate line could be written by nothing except
  the hand-built `jq` the shim exists to replace. The flags are all-or-nothing, the verdict must be
  one of `gate_coverage.sh`'s six words, and a root is refused under the three verdicts that have
  none to attribute. `heuristic` is **not** a flag: it is always `true`, and `--coverage-heuristic`
  is refused for the same reason `--ts` is — a caller able to drop the caveat could publish the
  count as a proof, which is the single thing the field exists to prevent.
- **`disclosure` is now a sixth event.** Ship's new disclosure had a documented shape, an
  extension point and a driver instructed to journal it, against a script whose event whitelist
  would have refused it with exit 2. `--kind` is deliberately unenumerated, matching
  `escalation`'s `--reason`, because both are documented as the place a new value goes; `--pr` is
  `null` rather than absent under `--no-pr`, since the disclosure was still made, into the report.

Both are asserted in `tests/cases/journal_append.sh`, including the check that every invocation
documented in `skills/auto-unattended/` is *executed* by the case — which is what would have caught
either of them at the point the second lane wrote its docs.

- The `human_only` placeholder in the task template and `examples/task.md` is commented out. Live,
  it would have made every `task.md` written from the template report `present`, putting the new
  heading on every pull request with placeholder prose beneath it — which destroys the property the
  fixed heading exists for. Same reasoning as fencing the fork checkbox in the same file.

## 0.3.0

**The first released version.** 0.1.0 and 0.2.0 were developed in the open but never tagged or
published, so there is no upgrade path from them and nothing to migrate; they are recorded below as
history.

The theme is that the plugin's one claim is now demonstrable rather than argued. gantry says a
guarantee belongs in a script's exit code rather than in prose — and until this release, prose was
the only thing that had ever checked the two scripts carrying that guarantee.

**Added**
- `tests/` — a fixture-repo suite over `lib/run_gates.sh`, `hooks/readiness-gate.sh` and
  `lib/detect_stage.sh`. Ten cases, no framework: build a throwaway repo, run the script, compare
  one integer. Covers the block-on-red dispatch, all three firing conditions against every status
  value, `stop_hook_active` and its jq-failure path, the frontmatter parser's six documented
  tolerances and its rejections, a broken install failing red, the kill switch, gate resolution
  order, the 2-and-3-normalise-to-1 rule, `NO-GATES` lenient versus `--strict`, and a monorepo
  subproject failure. Run with `bash tests/run.sh`; `scripts/verify.sh` runs it too, so CI needs no
  change. Confirmed non-vacuous: changing the hook's red dispatch from `exit 2` to `exit 0` is
  caught by five of the ten cases.
- `tests/cases/hook_worktree_root.sh` — the case the suite above could not express. Every other
  case runs through `lib.sh`'s `run_hook()`, which points `CLAUDE_PROJECT_DIR` and the payload's
  `cwd` at the *same* directory; under that shape the worktree bug is invisible, so a suite written
  to prove the guarantee would have passed in full while the guarantee never fired. This case makes
  the two disagree on purpose. Negative-tested: three of its seven assertions fail against the
  pre-fix hook and the other four — the ones guarding an over-correction — still pass.
- `scripts/context_budget.sh` — the always-on context cost as an exit code, wired into
  `verify.sh`. It counts description characters as a proxy (stated as one) because the enforced
  check cannot depend on the `claude` CLI that CI runners lack; the CLI remains the authority.
- A CI job on tags asserting the tag matches `plugin.json`'s `version`, so a release and its
  manifest cannot disagree.

**Fixed**
- **The readiness hook could never arm on a worktree run** — which is gantry's own default
  workflow, and every shape `/gantry:worktree` and the drivers produce. `hooks/readiness-gate.sh`
  took its `ROOT` from `$CLAUDE_PROJECT_DIR`, which stays pinned to the checkout the session
  launched from, while `lib/detect_stage.sh` took it from `git rev-parse --show-toplevel`. The two
  therefore read *different* `task.md` files, so the hook saw whatever status the main checkout was
  left on, skipped, and logged `decision=skip reason=status:shipped` forever. The hook now resolves
  the worktree containing the payload's `cwd` first, falling back to the old chain when there is no
  cwd or it is not in a repo.

  This also fixes `detect_stage.sh`'s `HOOK:` line, which was reporting `armed` on exactly the runs
  where the hook could not fire — the detector resolved to the worktree and saw `implementing`
  while the hook resolved elsewhere and saw something else. That line exists so a skill can say
  whether the gate is really enforced rather than imply it; it was doing the implying. One root,
  one answer, both sides.

  `tests/cases/hook_worktree_root.sh` asserts the behaviour: a worktree marked `implementing` over a red gate
  must block, the same worktree marked `shipped` must stay inert, and a payload with no cwd must
  still fall back to `$CLAUDE_PROJECT_DIR`.
- **The readiness hook logged nothing on the one path where the gate is silently bypassed.** Every
  `log_line` on the firing path ran after `run_gates.sh` returned, while the hook's own header
  documents that a hung gate is killed by the harness at its 300s limit with no `exit 2` produced
  and the stop proceeding un-gated. The single case the audit trail exists for was the single case
  it missed. An `arm` line is now written before the gate starts, so a killed hook leaves a dangling
  `arm` with no outcome. The claims in `README.md` and `docs/METHOD.md` are corrected to match.
- **The readiness hook created `.claude/artifacts/` in every repo you opened.** `mkdir -p` ran
  before any firing condition, and the hook is registered on `Stop` and `SubagentStop` with matcher
  `*` — so installing gantry meant every repository acquired a directory and a skip line per stop,
  once per sub-agent, for a plugin it never opted into. The `task.md` and `.claude/gates.sh` tests
  now run first and a repo failing either exits inert and silent. Ordering them ahead of
  `stop_hook_active` is safe: a repo that never runs the gate cannot produce the block a later stop
  would be caused by.

**Removed**
- **`gantry-verifier`.** It shipped in both prior versions and nothing ever dispatched it, which
  three documents said while defending it as an open question. It was not one: the gate is a script
  so that "did it pass" is an exit code rather than a model's judgment, and an agent that cannot be
  wired in without contradicting that argument is just ~70 always-on tokens per session with no
  caller. The roster is now `gantry-explorer`, `gantry-critic` and `gantry-reviewer`, all read-only.

**Changed**
- Always-on context is **measured** at ~1,464 tokens rather than derived — twelve skills and three
  agents, read from `claude --plugin-dir . plugin details gantry`. v0.2 published ~1,545 scaled from
  v0.1's reading. `README.md` and `docs/SKILLS.md` carry the read figures, and the budget script now
  enforces them.

## 0.2.0 — developed, never released

The pipeline comes apart into phases. v0.1 had two monolithic pipeline skills; v0.2 has one chain
of individually invocable phase skills and two drivers that invoke them. You can now type the
chain yourself, drop out of it to work by hand, and pick it back up.

**Added**
- Five phase skills: `plan`, `grill`, `implement`, `review`, `handover`. Each is invocable on its
  own and resolves its own position from disk rather than from the conversation.
- `grill` — the critique step v0.1 had nothing equivalent to. It **always** dispatches a fresh
  critic sub-agent, in every mode, because a context that wrote a plan cannot grill it.
- `handover` — writes `handover.md` at the worktree root: what a change deliberately left, why, and
  the next action. Committed with the branch, so it reaches the PR. Distinct from `preserve`, which
  records conversation reasoning outside the repo.
- Two agents: `gantry-critic` and `gantry-reviewer`, both read-only.
- `lib/detect_stage.sh` — one read-only reader of "where is this task", shared by every phase.
- `ship --draft`, which `auto-unattended` always passes.
- `.claude/gates.sh` for this repo, execing `scripts/verify.sh`. gantry shipped a hard gate and did
  not apply it to itself: with nothing to auto-detect here, `run_gates.sh --strict` reported
  NO-GATES and refused to push, so an unattended run on gantry had to drop `--strict` or supply the
  file by hand. It also arms the readiness hook on this repo.

- **`ship` reviews before it pushes.** A stage between the commit and the push invokes
  `/code-review --fix` over the branch diff, commits what it applies as its own commit, and
  re-runs the gate over the result — a red gate there stops the push. It exists for the caller who
  types `/gantry:ship` directly on a small change: previously that opened a PR nothing had read.
  Skipped by `--no-pr`, and by the new **`ship --reviewed`**, which both drivers always pass so a
  chain that already ran `/gantry:review` is not reviewed twice.
- **An open fork blocks the plan stage.** `lib/detect_stage.sh` reports a new `FORKS:` line
  (`open` | `none` | `unknown` | `absent`) from `task.md`'s *Open questions*, and the phases route
  on it: `plan` and `grill` will not mark a task ready while a fork is undecided, `auto` puts the
  open forks to you in one `AskUserQuestion` round after plan *and* after grill, and
  `auto-unattended` journals an `escalation`, sets `status: blocked`, and stops. `implement`
  refuses outright when a driver dispatched it, and warns when you typed it yourself.
  `scripts/verify.sh` asserts the parser against fixtures.
- `journal.jsonl`'s `escalation` event, reserved since v0.2's first draft, is now emitted — by the
  unattended open-fork stop.

**Changed**
- `factory` is renamed **`auto-unattended`**, and `--autonomous` is gone. A flag that silently
  removes every checkpoint is too easy to append to a command you meant to supervise; typing the
  unattended command is a deliberate act.
- `auto` and `auto-unattended` contain **no phase logic**. They invoke the same skills you would
  type, so the three ways of running cannot drift into three pipelines.
- **Delegation moved one level down.** The drivers no longer wrap each phase in a sub-agent; they
  invoke the phase skill, and the phase dispatches its own scoped agent for the sub-job — `plan` the
  explorer, `grill` the critic, `review` the reviewer. Wrapping a phase in an agent forced a choice
  between a writable agent (no boundary) and a phase that could not write its own artifacts; this
  way every shipped agent is read-only and the writing stays where you can see it.
- `gantry-planner` and `gantry-implementer` are **removed**. They existed to be the sandbox a driver
  dispatched a phase into, and that job no longer exists. The roster is now `gantry-explorer`,
  `gantry-critic`, `gantry-reviewer`, and `gantry-verifier`.
- `journal.jsonl`'s `agent` event becomes **`phase`**, with an `agents` array recording which
  sub-agents the phase actually dispatched. That array is the delegation roll-call the final report
  is checked against.
- **An unattended run no longer resolves a design fork by guessing.** It used to record the fork
  under *Open questions* and "take the conservative reading" — but an assumption written into a
  plan is indistinguishable from a decision, and by the time it surfaced there was an
  implementation on top of it. A genuine fork now stops the run and escalates. Judgement calls
  inside a plan still take the conservative reading; the distinction is whether two answers would
  send the work in materially different directions.
- **`task.md` and `plan.md` are now written in every mode**, not just the delegated one. This
  closes a real hole: the readiness hook arms on `task.md`, so in v0.1 the hook could never fire
  under `auto` — the headline skill's gate was unenforced. The hook's arming condition is unchanged.
- `run_gates.sh` moved from `skills/auto/scripts/` to `lib/`, now that the gate belongs to
  `implement` rather than `auto`. The hook's resolution was updated to match.
- `task.md`'s `status` vocabulary gains `planning`, `grilled`, `implemented`, and `reviewed`. The
  hook still arms on exactly `implementing` and ignores the rest.
- Always-on context is roughly **a third higher** (~1,157 → ~1,550 tokens, derived rather than
  measured). The phase skills carry deliberately terse descriptions to hold it down.

**Fixed**
- The hook sequence diagram in `docs/METHOD.md` failed to render on GitHub: mermaid treats `;` as a
  statement separator, and one message contained a semicolon. Found by parsing every diagram in the
  repo with mermaid itself — the check that was missing when the previous diagram bug shipped.
- `auto` used `AskUserQuestion` without declaring it in `allowed-tools`.
- `ship` pointed at a `status` skill that had already been removed.
- `scripts/verify.sh` now proves the frontmatter parser duplicated between the hook and
  `detect_stage.sh` has not drifted, and that the task template and its example stay identical.
**Not done, deliberately** — `auto-unattended` was considered for rebuild on Claude Code's Workflow
tool and rejected for now: workflows are plan-gated, and whether `Stop`/`SubagentStop` hooks fire
for workflow-spawned agents is undocumented. If they don't, the unattended mode loses the
unskippable gate in the one mode where nobody is watching. See `docs/ARCHITECTURE.md` § "Why the
unattended runner isn't a Workflow".

## 0.1.0 — developed, never released

The extraction itself: a workflow that had been running privately, made portable and packaged as a
Claude Code plugin.

**Added**
- Seven skills: `auto`, `factory`, `ship`, `worktree`, `sync`, `prune-worktrees`, `preserve`.
- A four-agent roster (`gantry-explorer`, `gantry-planner`, `gantry-implementer`,
  `gantry-verifier`), shipped with the plugin so `factory` works with no setup.
- The readiness hook, registered on `Stop` and `SubagentStop`, inert until armed by a
  `.claude/gates.sh` plus a `task.md` at `status: implementing`. Kill switch:
  `GANTRY_READINESS_GATE=off`.
- `docs/METHOD.md`, `docs/ARCHITECTURE.md`, `docs/SKILLS.md`, and `examples/gates.sh`.

**Changed from the private original**
- `factory` no longer stops when a repo has no `.claude/agents/`. Roster resolution is now per
  role, repo first, falling back to the shipped agents.
- The readiness hook resolves `run_gates.sh` by self-location rather than two hardcoded paths.
- `sync`'s external profile lookup is documented as an optional integration you can implement
  yourself, rather than as a dependency.

**Known limitations** — see `docs/METHOD.md` § "Where this is wrong". In short: the hook's arming
condition is a file the model can write; `gantry-verifier` ships but is not dispatched; and
auto-detection can report `NO-GATES` on a repo whose real checks it cannot see.
