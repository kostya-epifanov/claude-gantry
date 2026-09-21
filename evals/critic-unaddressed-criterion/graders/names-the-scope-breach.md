---
type: llm
weight: 2
---

The second seeded defect. The fixture's `task.md` puts `bin/upload.sh` and the remote store out of scope, and says the upload path's cutoff is computed separately on purpose. Step 3 of the fixture's `plan.md` adds `newer_than` to the library and changes `upload.sh` to call it — work the contract excludes, justified by a de-duplication argument the contract has already rejected.

PASS only if the response reports that a plan step does work the task puts out of scope, identifying it as step 3, as the `upload.sh` change, or as the cutoff consolidation.

FAIL if the response never connects a plan step to the Out of scope section. Praising step 3 as a useful tidy-up is a FAIL. Reporting the other seeded defect instead does not satisfy this grader.
