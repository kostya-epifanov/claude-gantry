---
id: 2026-05-06-tally-words
title: tally.sh gains a --words flag
status: grilled
---

## Context & goal

`bin/tally.sh` prints the line count of a file. The word count is wanted just as often, and
`lib/tally.sh` already computes it — `count_words` is there and nothing calls it. The command
needs a way to ask for it.

## Acceptance criteria

- [ ] `tally.sh --words <file>` prints the number of whitespace-separated words in the file and
      exits 0.
- [ ] `tally.sh <file>` still prints the line count and exits 0. The default does not change.
- [ ] A file that does not exist still exits 2 with a message on stderr, under either mode.
- [ ] An unrecognised flag exits 2 with the usage line on stderr and counts nothing.

## Out of scope

- Reading from standard input. The command takes a path and only a path.
- A character count, and any other new counter.
- Changing what `lib/tally.sh` computes or how.

## Open questions

- [x] Long flag, short flag, or both? Decided: `--words` only. One spelling is one thing to
      document and one thing to test.
