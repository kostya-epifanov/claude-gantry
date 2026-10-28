---
id: 2026-07-18-contact-form   # the tracker id (BASE-71, GH-71) when the task has one; else date-slug
title: Add contact form to marketing site
project: acme-site
branch: task/contact-form
mode: semi-auto           # semi-auto | auto | unattended — which mode is driving
status: planning          # planning | planned | critiqued | grilled | implementing |
                          # implemented | reviewed | shipped | blocked. `planned` means
                          # drafted, `critiqued` means a critic read it, `grilled` means a
                          # human agreed — only the last is an approval. The readiness hook
                          # arms on exactly `implementing` and ignores every other value.
---

## Context & goal

Why this exists, and what the feature is. One or two paragraphs — enough that someone
picking the task up cold knows what problem it solves, not just what to type.

## Acceptance criteria

- [ ] A checkable statement — true or false, no judgement call.
- [ ] Another one. Keep them observable; "works well" is not a criterion.

## How to verify

```yaml
verification:
  automated:
    lint: true
    tests: true
    e2e:
      setup: { use_profile: true }   # applied by the repo's .claude/qa-env.sh
      scenarios:
        # Uncomment and replace. `/gantry:qa` runs each entry against the built
        # app, and `gantry:ship` puts one that was not run under "Not proven by
        # this run" — so a live placeholder here would put a scenario called
        # "scenario name" on every PR. Empty `steps` = the agent derives them.
        # - name: "scenario name"
        #   goal: "what success looks like, in a sentence"
        #   steps: []
  human_only:
    # Uncomment and replace. Every entry here is surfaced verbatim in the pull
    # request body under "Not proven by this run", so leaving the placeholder
    # live would put that heading on every PR with this sentence beneath it.
    # - "the subjective or unautomatable check a person must make"
```

## Out of scope

- What this task explicitly does not do. This section is what stops scope creep,
  so write it even when it feels obvious.

## Affected areas

Filled by the explorer during code study — files, entry points, patterns in play,
and the risks a change here would hit. Left empty until then.

## Decisions

Written by `gantry:grill` as the conversation settles each fork: the question, the
options considered, what was chosen, and **why**. One entry per question.

This is the section `gantry:ship` quotes into the pull request body, so it is how
the reasoning behind the approach reaches a reviewer at all. Leave it empty here;
a plan that has not been grilled yet has nothing to put in it.

Anything marked *decided by recommendation, unconfirmed* was decided for the user
rather than by them — grill does that when the reply was "go with your
recommendation", and says so rather than recording a confirmation nobody gave.

## Open questions

The forks the implementer must not resolve alone. Carried from the pre-plan
braindump; each one checked off as it is decided, never deleted — a deleted entry
reads exactly like one that was never raised.

This section is a **precondition, not a note**. `lib/detect_stage.sh` parses it,
`grill` will not reach its approval while a fork is open, and `implement` refuses
outright when a driver dispatched it. Supervised runs settle the open forks inside
`grill`; unattended runs stop and escalate rather than guess.

Write each entry as a checkbox — an unchecked box, or a bare bullet with no box at
all, counts as open:

```
- [ ] Postgres or SQLite? Changes the migration story and the deploy.
- [x] Replace the existing endpoint rather than add one — decided: no callers left.
```

An empty section, or one that just says `None.`, is settled.
