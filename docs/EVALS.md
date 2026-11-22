# Evals

`tests/` proves that gantry's scripts keep their exit-code guarantees. It says nothing about
whether the *agents* produce good work. Every change to `agents/gantry-critic.md` or to a skill's
prose has so far been judged by reading it, which is an opinion about a prompt rather than a
measurement of its output.

`evals/` is the first thing here that produces a number. It is a floor, not a benchmark — five
cases, two agents, run by the harness Claude Code already ships.

## What is in it

Five cases, each a directory under `evals/`:

| Case | Agent | Kind | The seed |
|---|---|---|---|
| `critic-missing-interface` | critic | seeded | A plan step calls a helper the source does not have, with the arguments reversed and an exit-status behaviour the real one lacks. |
| `critic-unaddressed-criterion` | critic | seeded ×2 | An acceptance criterion no step touches, and a step doing what *Out of scope* forbids. |
| `critic-sound-plan` | critic | control | Nothing wrong with it. |
| `reviewer-broken-caller` | reviewer | seeded | A change updates one of two callers; the stale one is in the tree but not in the diff. |
| `reviewer-clean-change` | reviewer | control | A small correct refactor with every call site updated. |

The controls are half the suite for a reason. An agent that always finds something scores full
marks on every seeded case and is useless; only a control says so.

A **seeded** case's grader names the defect, so it fails when the defect is not reported. A
**control**'s grader names the *absence* of one, so it fails when a defect is asserted. Neither is
a "was the output good" rubric — those grade fluency.

Each case also carries a free `regex` grader and a `tool_used` indicator marked `arm: with-only`.
The indicator is excluded from the score: it exists to show whether the plugin arm actually
dispatched the sub-agent, which an agent-neutral prompt leaves the model free not to do.

## Running it

One case first, always. A full run costs real money and a malformed case is cheapest to find
alone:

```bash
claude plugin eval . --case critic-missing-interface --max-cost-usd 3 --no-publish
```

Then the suite:

```bash
claude plugin eval . --max-cost-usd 10 --no-publish
```

Notes on the flags, each of which changes what the command does rather than how it reads:

- **`--no-publish`.** The harness publishes its HTML report to claude.ai by default. The report
  contains the prompts, the model's full responses and the graders' verdicts. Pass `--no-publish`
  unless you mean to publish those.
- **`--max-cost-usd`.** A ceiling, checked before each run launches. Hitting it is **exit 2 with
  `partial: true`** — not a harness error and not a completed run. Read it as "no answer yet".
- **`--case <glob>`** and **`--tag critic|reviewer|seeded|control`** narrow what runs.
- **`--runs 1`** cuts a pilot to a third of the cost. It also makes the score much noisier; use it
  to check that cases parse, not to compare two versions of a prompt.
- The first run in this directory asks you to confirm you trust the plugin. `--trust-plugin`
  answers that for CI.

Exit codes are the harness's: 0 when every case scored at or above `--threshold` (default 1.0),
1 when one did not, 2 when the run could not finish or hit the ceiling.

### From inside a gantry worktree

You cannot. An isolated worktree session refuses any command containing the word `eval` — it reads
as shelling out to `eval`. Run it from a plain shell, or prefix it with `!` in a Claude Code
session that is not isolated.

## What it costs

Nobody has measured it yet. The arithmetic, which is what there is:

- 5 cases × `runs: 3` (the default, and no case overrides it) = **15 agent runs per arm**.
- `--ablation with-without` is the default whenever a plugin resolves, so there are **two arms** —
  with the plugin and without it — and therefore **30 agent runs** for a full suite.
- Each `llm` grader is a separate judge call. The judge runs on **haiku** by default
  (`--judge-model` overrides it), so the graders are a rounding error beside the runs.
- `regex` and `tool_used` graders are free. When the cost ceiling stops a run, the paid graders are
  skipped and the free ones still score it — which is why every seeded case has one.

`--max-cost-usd 10` is the documented ceiling for a full run. It is a guess until somebody records
what the first one actually spent; if you run it, put the figure here.

## Adding a case

Copy the nearest existing case and change four things:

1. **Rename the directory**, and set `name:` in `case.yaml` to match it. `--case` filters on that
   name, and `scripts/check_evals.sh` fails the mismatch.
2. **Rename the fixture directory** to match the case, and update `context.add_dirs`. The name is
   unique per case on purpose: a `Glob` inside a run can then never land on another case's
   identically named `task.md` and be graded against the wrong fixture.
3. **Change the seed.** Put it in prose and in code, never in a markdown link — `scripts/verify.sh`
   resolves every relative link in every `*.md` in the tree, fixtures included, so a plan that
   points at a file which does not exist turns the gate red instead of seeding a case. Fixture
   shell must pass `bash -n` and `shellcheck -S warning` with no `# shellcheck disable=` lines; a
   disable comment is also a tell that points the evaluated agent straight at the seed.
4. **Name the defect in the grader.** The rubric describes the specific thing that must be
   reported, and says what a FAIL looks like. A grader that asks whether the critique was thorough
   measures fluency.

Then `bash scripts/check_evals.sh` — free, no CLI, no credential — and a single-case run.

If the case ships a `change.diff`, the tree beside it is the **post-change** state and the diff is
what was applied to reach it. The lint reverse-applies the diff to check the two have not drifted:
a fixture whose diff no longer matches its files scores a correct "this diff does not apply" as a
miss.

## What the numbers do not prove

- **Small n.** Three runs per case per arm. A one-case difference moves the score by a third.
- **The judge is a model.** An `llm` grader's verdict is another model's reading of the rubric.
- **The delta confounds two things.** The with-plugin arm dispatches a sub-agent pinned to
  `model: opus`; the baseline arm has no such agent and critiques inline on the session's default
  model. A positive delta is "this plugin's agent, on its model" beating "no plugin, default
  model" — not evidence about the agent's prose on its own.
- **Dispatch is not guaranteed.** The prompts are agent-neutral so that the baseline arm can run
  them at all, which leaves the plugin arm free to do the work inline. The `with-only`
  `tool_used` indicator is how you tell; it is reported and not scored.
- **The reviewer runs with one hand tied.** These cases grant no `Bash` and ship no git
  repository, so nothing here exercises the part of `gantry-reviewer` that gets the diff right —
  the uncommitted tree, `git status --short`, reading untracked files, running a test to check a
  claim. That was the price of keeping the whole suite free of `--allow-tools` and `--scaffold`,
  and it is a real gap, not a rounding error.
- **The fixtures are tiny.** Three or four small files. Nothing here measures behaviour at any
  depth of context, which is where both agents actually work.
- **Nothing measures whether the seeds are good.** A seed that is always found, or never, carries
  no signal. Only repeated runs show that, and tuning a seed until the score improves measures the
  seed.

## What the gate does check

`scripts/verify.sh` runs `scripts/check_evals.sh`, which costs nothing and needs no CLI: every case
declares a turn and a time bound, asks only for tools that need no `--allow-tools` grant, declares
no `scaffold_script`, names fixture directories that exist, has at least one grader with a type the
harness knows, and ships no `change.diff` that has drifted from its tree. A checkout with no
`evals/` passes.

It does **not** check that a case parses under the real harness — there is no dry-run mode, and
`claude plugin validate` does not read eval cases. The lint reads a flat subset of YAML with
`grep`, `sed` and `awk`, and its schema was read out of the shipped binary on 2026-09-20. The only
proof a case runs is a run.

CI does not run evals: it has no `claude` CLI and no credential. It gets the structural lint only.

See [METHOD.md](METHOD.md) for why a guarantee lives in an exit code here, and
[../CONTRIBUTING.md](../CONTRIBUTING.md) for the rest of the local loop.
