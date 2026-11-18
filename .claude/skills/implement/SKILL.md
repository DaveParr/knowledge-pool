---
name: implement
description: "Implement a piece of work based on a spec or set of tickets."
disable-model-invocation: true
---

Implement the work described by the user in the spec or tickets.

Use /tdd where possible, at pre-agreed seams.

Run typechecking regularly, single test files regularly, and the full test suite once at the end.

## Review it (required)

Don't commit or report done until this step has run. It applies to Orca workers too: this skill asks you to start the two `/code-review` subagents, which is the exception the Orca preamble's "no subagents unless the task asks" allows. Don't replace them with a review of your own.

Run /code-review with:

- **Fixed point**: the branch your work merges into, e.g. `origin/DaveParr/planning-deployment` (the diff is against its merge-base). Don't ask the user for one.
- **Spec**: the ticket(s) you implemented, or the spec you were given.

Fix every finding, rerun the tests, and review again until nothing is left. A finding you deliberately leave unfixed needs a one-line reason.

## Commit

Commit your work to the current branch. Include the final review result in your report (and in `worker_done` evidence if you are an Orca worker).
