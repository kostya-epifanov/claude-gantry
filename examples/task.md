---
id: 2026-07-18-contact-form
title: Add contact form to marketing site
project: acme-site
branch: task/contact-form
mode: semi-auto           # semi-auto | auto | unattended — which mode is driving
status: planning          # planning | planned | grilled | implementing | implemented |
                          # reviewed | shipped | blocked. The readiness hook arms on
                          # exactly `implementing` and ignores every other value.
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
      setup: { use_profile: true }
      scenarios:
        - name: "scenario name"
          goal: "what success looks like, in a sentence"
          steps: []                # optional; empty = agent derives from goal
  human_only:
    - "the subjective or unautomatable check a person must make"
```

## Out of scope

- What this task explicitly does not do. This section is what stops scope creep,
  so write it even when it feels obvious.

## Affected areas

Filled by the explorer during code study — files, entry points, patterns in play,
and the risks a change here would hit. Left empty until then.

## Open questions

The forks the implementer must not resolve alone. Carried from the pre-plan
braindump; each one checked off as it is decided, never deleted — a deleted entry
reads exactly like one that was never raised.

This section is a **precondition, not a note**. `lib/detect_stage.sh` parses it,
`plan` and `grill` will not mark the task ready while a fork is open, and
`implement` refuses outright when a driver dispatched it. Supervised runs put the
open forks to you; unattended runs stop and escalate rather than guess.

Write each entry as a checkbox — an unchecked box, or a bare bullet with no box at
all, counts as open:

```
- [ ] Postgres or SQLite? Changes the migration story and the deploy.
- [x] Replace the existing endpoint rather than add one — decided: no callers left.
```

An empty section, or one that just says `None.`, is settled.
