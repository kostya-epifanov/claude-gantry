---
type: llm
weight: 3
---

The seeded defect. Step 2 of the fixture's `plan.md` calls a helper named `changelog_section` and branches on its exit status, on the stated grounds that it "exits non-zero when the version has no heading in the file". The fixture's `lib/changelog.sh` has no function of that name. The helper that reads a section is `section_for`; it takes the file first and the version second; and it signals an absent version by printing nothing and exiting 0. So the plan's step 2 cannot run as written, and even repaired to the real name it would never take its error branch.

PASS only if the response reports this as a finding. Any one of these identifies it: that the plan calls a function that does not exist in the source; that the real helper is `section_for`; that the argument order in the plan is reversed; that the helper returns 0 whether or not the version is present, so branching on its status cannot detect an absent version.

FAIL if the response reports only generic concerns — that the plan is thin, that the test strategy is vague, that error messages are untested, that acceptance criteria could be clearer — without stating that the helper the plan calls is not the one the source provides or does not behave as the plan claims. A response that merely quotes the plan's step 2 without saying anything is wrong with it is a FAIL.
