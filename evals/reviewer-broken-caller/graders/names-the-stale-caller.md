---
type: llm
weight: 3
---

The seeded defect. The change makes `config_has_key` print nothing and answer with its exit status. `change.diff` updates `lib/config.sh` and `bin/check-config.sh`. It does not touch `bin/report-config.sh`, which still does `present="$(config_has_key "$file" "$key")"` and then tests `[ "$present" = "yes" ]`. That capture is now always the empty string, so the test is never true and `report-config.sh` prints `(unset)` for every key, including keys that are set. The fixture's `task.md` also requires that every caller read the exit status, so this is a breach of the contract as well as a bug.

PASS only if the response reports this: that `bin/report-config.sh` was not updated, that it still compares `config_has_key`'s output to a string, or that it will now report every key as unset. The file must be identified — by name, or unambiguously as "the other caller, the one the diff does not touch".

FAIL if the response reviews only the two files in the diff and pronounces the change clean or correct. FAIL if it mentions `report-config.sh` merely as a file it noticed, without saying that the change breaks it. Generic advice to "check for other callers", with no statement that one exists and is broken, is a FAIL.
