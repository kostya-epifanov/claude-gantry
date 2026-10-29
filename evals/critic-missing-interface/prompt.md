A fixture project has been added to this session as an extra working directory. Its name begins with `fixture-`. Find it first, then work inside it.

It holds a task contract in `task.md`, an implementation plan in `plan.md` written against that contract, and the source the plan proposes to change. Nobody has implemented the plan yet.

Critique the plan, against the task and against the source, the way you would before anyone spends a day discovering the problem. If a plan-critic sub-agent is available to you, delegate the critique to it and tell it where the fixture is; if none is available, do the critique yourself.

Read enough of the source to know whether each step would actually work. A step that assumes a function, an argument order or a behaviour the code does not have is worth more than any number of observations about wording.

Report findings only — write and edit nothing. Give every finding a severity (blocking, worth fixing, or noted) and a concrete consequence: what goes wrong, in what case. If you find nothing worth acting on, say that plainly rather than padding the list.
