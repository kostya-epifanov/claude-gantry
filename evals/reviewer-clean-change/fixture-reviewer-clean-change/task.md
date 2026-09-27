---
id: 2026-07-02-table-row-helper
title: One place for the two-column row
status: implemented
---

## Context & goal

`lib/table.sh` declares `TABLE_LABEL_WIDTH` and nothing reads it: both report scripts write the
width as a literal in their own `printf`. Changing the layout means editing every call site and
hoping none was missed, which is the failure the constant was added to prevent. Give the library
the row as well as the heading.

## Acceptance criteria

- [ ] `lib/table.sh` gains a `row <label> <value>` that lays out one row using
      `TABLE_LABEL_WIDTH`, so the width is read rather than repeated.
- [ ] Both report scripts call it. No literal column width is left in `bin/`.
- [ ] Output is byte-for-byte what it was before the change at the current width.

## Out of scope

- Any change to the layout itself — a different width, a separator, colour, alignment.
- `heading`, which is already shared and is not being touched.
- Making the scripts usable as libraries, or adding a third report.

## Open questions

- [x] Should `row` take the width as an optional third argument? Decided: no. One width is the
      point of the constant; a per-call override would put it back where it was.
