---
name: implement
description: "Implement a piece of work based on a spec or set of tickets."
---

Implement the work described by the user in the spec or tickets.

Use /mattpocock-skills:tdd where possible, at pre-agreed seams.

Run typechecking regularly, single test files regularly, and the full test suite once at the end.

## Review it (required)

Don't report done until this step has run. Ticket workers commit and open the PR first, then review the PR in rounds and post each round to it; follow that order there. It applies to Orca workers too: this skill asks you to start the two `/code-review` subagents, which is the exception the Orca preamble's "no subagents unless the task asks" allows. Don't replace them with a review of your own.

Run /code-review with:

- **Fixed point**: the branch your work merges into, e.g. `origin/main` (the diff is against its merge-base). Don't ask the user for one.
- **Spec**: the ticket(s) you implemented, or the spec you were given.

Review in rounds: two normally, three at most, the last on the final head. Each round, when you work on a PR, posts two comments: `## Code review, round <k>` (the head commit reviewed, then the findings, numbered) and `## Round <k> response` (one line per finding: **fixed** with the commit, or **left** with a one-line reason; nothing unanswered). Fix the findings, rerun the tests, and push before the next round.

## Commit

Commit your work to the current branch. Include the final review result in your report (and in `worker_done` evidence if you are an Orca worker).
