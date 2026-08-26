# Skill authoring reference

Rules that decide whether a skill gets found and whether it earns its context.
Read this before writing a `SKILL.md`; `validate_skill.py` enforces the mechanical half.

## Contents

- Frontmatter fields
- Who invokes it — the first decision
- Writing the description
- Naming
- The body budget
- Progressive disclosure
- Degrees of freedom
- Anti-patterns
- Evals

## Frontmatter fields

Only `description` really matters to start. Most skills need the first four and nothing else.

| Field | Use |
|---|---|
| `name` | Display label only. The **directory name** is what you type after the slash. Keep them equal anyway. |
| `description` | What it does *and* when to use it. The whole discovery mechanism. |
| `argument-hint` | Autocomplete hint, e.g. `[branch]`, `[issue-number]`. |
| `disable-model-invocation` | `true` = only you can invoke it. See below. |
| `when_to_use` | Extra trigger phrases, appended to `description` in the listing. |
| `arguments` | Named positional args for `$name` substitution. |
| `user-invocable` | `false` = only Claude can invoke it (background knowledge). |
| `allowed-tools` | Pre-approved tools while the skill is active — cuts permission prompts. Does **not** restrict anything. |
| `disallowed-tools` | Tools removed from the pool while active. |
| `model` / `effort` | Override for the rest of the turn. |
| `context: fork` + `agent` | Run in an isolated subagent; the body becomes its prompt. Needs an actual task, not just guidelines. |
| `paths` | Globs that limit automatic activation to matching files. |
| `hooks` | Hooks scoped to the skill's lifecycle. |

An unknown key is ignored **silently**, so `when-to-use` instead of `when_to_use` fails without a word. Malformed YAML is worse: the body still loads with empty metadata, so `/name` keeps working while automatic discovery is dead. Run `claude --debug` to see the parse error.

## Who invokes it — the first decision

| Frontmatter | You | Claude | Description in context |
|---|---|---|---|
| (default) | yes | yes | always |
| `disable-model-invocation: true` | yes | no | never |
| `user-invocable: false` | no | yes | always |

Gate it with `disable-model-invocation: true` when the skill has side effects or when timing is yours to choose — committing, deploying, sending a message, switching the session somewhere else. You don't want Claude deciding to deploy because the code looks ready.

The context consequence is real but smaller than it sounds: gating removes the *description* from every session's listing, not the name. `claude plugin details gantry@claude-gantry` shows what each skill actually costs, split always-on versus on-invoke.

Setting both `disable-model-invocation: true` and `user-invocable: false` makes the skill unreachable.

## Writing the description

This is the entire discovery mechanism — Claude picks from names and descriptions alone.

- **Third person.** "Creates a worktree…", never "I can help you…" or "You can use this to…". It's injected into the system prompt, and a shifting point of view confuses matching.
- **What it does *and* when to use it.** "Use when the user types /gantry:worktree with a branch name, or asks to start work on a new branch."
- **Key use case first.** The listing truncates at 1,536 chars combined with `when_to_use`, and shrinks further when many skills compete for the budget.
- **≤1024 characters.**
- **No angle brackets.** The spec forbids XML tags here. Write `[branch]` or "with a branch name" — not `<branch>`.
- **Lead with the words a user would actually type**, not the words you'd use to categorise it.

Claude under-triggers skills more often than it over-triggers, so lean slightly pushy on the phrasing. Note that Claude only reaches for a skill when the task looks like it needs one — a one-step request handled fine by plain tools may not trigger anything however good the description.

## Naming

Directory name = command name. Lowercase letters, digits, single hyphens; ≤64 chars; cannot contain `claude` or `anthropic`. Prefer a plain verb or noun phrase (`worktree`, `skill`, `deploy`), and stay consistent across gantry. Avoid `helper`, `utils`, `tools`.

Inside this plugin the namespace comes free: `skills/worktree/` → `/gantry:worktree`. Don't re-prefix directories with `gantry-`.

## The body budget

Once a skill loads, its rendered body enters the conversation and **stays there for the rest of the session** — Claude Code doesn't re-read the file on later turns. Every line is a recurring cost. After compaction the most recent invocation of each skill is re-attached, keeping the first 5,000 tokens, sharing a 25,000-token budget across all skills — so a bloated skill can push others out entirely.

Keep the body under 500 lines. Write standing instructions rather than one-time narration, since the text applies for the whole task. Say what to do; skip what Claude already knows.

## Progressive disclosure

```
skill-name/
├── SKILL.md        # overview + workflow; always loads
├── references/*.md # detail; loaded only when needed
└── scripts/*       # executed, never loaded into context
```

- **Reference from SKILL.md and say when to read it** — an unreferenced file is an unread file.
- **One level deep.** Claude partially reads files it reaches through another reference (often `head -100`), so a link-of-a-link loses content. Every reference links directly from SKILL.md.
- **Table of contents** for reference files over ~100 lines, so a partial read still reveals the full scope.
- **Prefer a script to generated code** for anything deterministic or repeated: more reliable, no tokens for the code itself, consistent every run. Say explicitly whether Claude should *run* it or *read* it — running is usually right.

## Degrees of freedom

Match specificity to fragility.

- **Fragile, sequence-critical, destructive** → exact commands, no room to improvise.
- **A preferred pattern exists** → a template with parameters.
- **Many valid paths, context decides** → direction only; trust Claude to route.

Over-constraining an open task wastes tokens and produces worse work than saying less.

## Anti-patterns

- **Time-sensitive statements.** "Before August, use the old API" rots. Put superseded material under an "Old patterns" heading instead.
- **Inconsistent terminology.** Pick one word — "field", not field/box/element/control — and keep it.
- **Windows-style paths.** Always forward slashes.
- **A menu of options.** Give one default plus an escape hatch, not five libraries to choose between.
- **ALL-CAPS MUST/ALWAYS/NEVER.** Occasionally warranted; usually a sign the *why* is missing. Explaining the reason travels further than shouting the rule, because it generalises to cases you didn't foresee.
- **Overfitting to the example you tested on.** A skill runs on prompts you never saw.

## Evals

Triggering isn't working. Measure two things separately: does it fire on the prompts it should, and is the output right when it does.

Both are baseline comparisons — same prompt, with and against without. Use a **fresh session**: leftover context from authoring masks the gaps in what you actually wrote.

Inside this plugin the harness is built in:

```bash
claude plugin eval gantry@claude-gantry --case 'name*' --ablation with-without
```

It runs each case against the plugin and against a no-plugin baseline arm, then reports the score delta — pass rate against the token and time overhead. `claude plugin eval init` authors a suite interactively. Worth it where output is objectively checkable; skip it for subjective work and judge by hand.

For a deeper loop — automated description tuning, blind A/B between versions — Anthropic's `skill-creator` plugin does that and nothing here needs to duplicate it. Its own validator targets the portable spec and rejects Claude Code fields like `disable-model-invocation`, so don't run that part against these skills.
