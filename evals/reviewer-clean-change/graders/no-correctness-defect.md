---
type: llm
weight: 3
---

This case has no seeded defect. The change moves a repeated `printf '%-24s %s\n'` into `row` in `lib/table.sh`, which reads `TABLE_LABEL_WIDTH` instead of repeating the literal. Both call sites — the only two in the fixture — are updated in the same diff, and the output is unchanged at the current width, so all three acceptance criteria are met.

PASS if the response asserts no correctness defect. Style, taste and robustness notes do not fail it: that `row` would fail under `set -u` if a caller passed one argument, that the constant is a global, that `heading` could take the same treatment, that a test would be nice — all of these are fine, and so is a response that lists them under "worth fixing" or "noted" while saying the change itself is correct. A response that finds nothing at all and says so is a PASS.

FAIL if the response asserts that the change is wrong: that a caller was missed, that output changes, that an acceptance criterion is unmet, that `row` mishandles its arguments as the existing call sites use them, or that the diff breaks something. Judge the claim, not the length of the list.
