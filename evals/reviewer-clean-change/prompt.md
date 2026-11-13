A fixture project has been added to this session as an extra working directory. Its name begins with `fixture-`. Find it first, then work inside it.

It holds `task.md`, the contract the change was written against; `change.diff`, an uncommitted change that has already been applied to the tree; and the source as it stands after that change.

There is no shell and no git repository in this environment. You cannot run `git diff`, `git status` or any other command — `change.diff` is the whole change, and reading that file is how you get it.

Review the change against the contract. If a code-review sub-agent is available to you, delegate the review to it and pass it those same facts: where the fixture is, that the diff file is the whole change, and that no shell is available. If none is available, review it yourself.

Read beyond the diff. A file the diff does not touch is the easiest place for a defect to survive a review.

Report findings most severe first, each naming its file and a concrete failure — inputs or state leading to a wrong result. Correctness before anything else; an opinion with no failure attached is not a finding. Write and edit nothing. If you find nothing wrong, say so plainly rather than padding the list.
