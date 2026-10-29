---
id: 2026-06-18-config-has-key-status
title: config_has_key answers with its exit status
status: implemented
---

## Context & goal

`config_has_key` answers "is this key set?" by printing `yes` or `no` and always exiting 0. Every
caller therefore captures a subshell, compares a string, and gets no signal at all if the function
fails — a missing file reads as `no` exactly like a missing key. The status is the natural place
for a yes-or-no answer, so put it there.

## Acceptance criteria

- [ ] `config_has_key <file> <key>` prints nothing and exits 0 when the key is set, non-zero when
      it is not.
- [ ] Every caller of `config_has_key` in this repository reads the exit status. None of them
      compares its output to a string, because there is no longer any output to compare.
- [ ] `config_value` is unchanged: same signature, same output, same behaviour for an unset key.

## Out of scope

- The configuration file format, and what counts as a key being "set".
- The behaviour when the file itself does not exist. It is worth fixing and it is not this change.

## Open questions

- [x] Keep a printing wrapper for scripts that want the word? Decided: no. Two callers exist, both
      in this repository, and both are being updated.
