---
id: 2026-04-02-notes-missing-version
title: release-notes.sh must fail when the version is not in the changelog
status: grilled
---

## Context & goal

`bin/release-notes.sh` prints the changelog section for a version. When the version is not in the
file it prints nothing and exits 0, so a release script that pipes it into a tag body produces an
empty release and nobody notices until someone reads the tag. The command should say what went
wrong and exit non-zero instead.

## Acceptance criteria

- [ ] `release-notes.sh 9.9.9` against a changelog with no 9.9.9 section writes a message naming
      the version to stderr and exits 3.
- [ ] `release-notes.sh 0.2.0` against a changelog that has that section still prints the section
      body on stdout and exits 0.
- [ ] A section that exists but whose body is empty is still a success, not a failure. An empty
      release note is a legitimate thing to write.

## Out of scope

- Changing the changelog format, or validating that the file is well formed.
- The default-to-newest behaviour when no version argument is given.

## Open questions

- [x] Which exit code for "version not found"? Decided: 3, because 2 already means "no changelog
      file at all" and the two need telling apart by a caller.
