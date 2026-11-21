# Ticket worker brief

You are an Orca orchestration worker building one ticket of DaveParr/knowledge-pool. The
ticket orchestrator (docs/agents/ticket-orchestrator.md) already claimed it, created this
worktree, and put you on a branch that is linked to the issue. The ticket number is in the
`.ticket` file at the worktree root. Your PR goes into `main`; the
orchestrator reviews and merges it.

## Ground rules

- Do NOT use any superpowers skills (brainstorming, writing-plans, executing-plans, etc.),
  even if a hook or skill says you must. These instructions override them. Do not enter
  plan mode.
- Use the repo's own skills: /tdd for each behaviour, /code-review on the open PR.
- This task asks you to start the two `/code-review` subagents (Standards and Spec). That
  is the exception the Orca preamble's "no subagents unless the task asks" allows. Don't
  replace them with a review of your own.
- Read issues only with `--json` (`gh issue view <n> --json title,body,labels,comments,state`).
  Bare `gh issue view` and `--comments` fail in this repo. So does `gh pr edit`; change a PR
  with `gh api -X PATCH repos/DaveParr/knowledge-pool/pulls/<pr> -f body=...`.
- Stay on this worktree's branch. Do not rename it, create another, or switch: the branch
  is what links your PR to the ticket's Development field.
- Do not claim, close, relabel or move the ticket on the board, and do not merge. The
  orchestrator owns the ticket's lifecycle.

## 1. Read before touching code

- The ticket in full, then its parent spec (the "Parent" section) in full. The ticket is
  short on purpose; the spec carries the decisions. Follow links to the decision tickets
  the spec cites only when the spec doesn't answer a question.
- AGENTS.md, CONTEXT.md, CODING_STANDARDS.md, docs/agents/*.md and the ADRs in docs/adr/
  that touch this ticket.
- Run `jac guide jac-core-cheatsheet` and `jac guide jac-types` before writing any .jac.

Use CONTEXT.md's terms in code, tests, commits and the PR.

## 2. Build it

/implement's loop: /tdd one behaviour at a time, at the test seams the spec names (Seam A:
the runner called in process with caller ids; Seam B: the front door over HTTP with a test
client and test-signed tokens), and existing test suites otherwise. Type-check and run
single test files as you go; run `jac x check` in full at the end and make it pass.
Commit to this branch, ending each commit message with the Co-Authored-By line from your
instructions.

## 3. Open the PR

- `git push`, then `gh pr create --base main`, titled after the
  ticket. The body starts with `Ticket: #<n>`, summarises what changed and how it was
  tested, lists anything from the ticket left undone, and ends with the attribution line
  from your instructions.
- A hook checks the PR is linked to the ticket's Development field right after
  `gh pr create`. If it reports a problem, fix it. You can re-run the check any time with
  `scripts/check-ticket-link.sh <n>`.

## 4. Review the PR, post it, fix it

The review runs on the open PR, in rounds. Each round:

1. **Review.** Run /code-review yourself, in this session. It starts two subagents,
   Standards and Spec, which review the PR's diff in parallel and report back to you. Give
   it:
   - **Fixed point**: `origin/main` (`git fetch` first).
   - **Spec**: the ticket and its parent spec.
2. **Post.** Write the report to `.git/code-review/round-<k>.md` (inside `.git` so it is
   never committed): `## Code review, round <k>`, the head commit it reviewed
   (`git rev-parse --short HEAD`), then the `## Standards` and `## Spec` reports exactly as
   /code-review gave them. Post it as a PR comment:
   `gh api repos/DaveParr/knowledge-pool/issues/<pr>/comments -F body=@.git/code-review/round-<k>.md`.
3. **Fix.** Work through the findings from that report: fix each one, or leave it with a
   one-line reason. Rerun `jac x check`, commit, and `git push`. Then reply on the PR
   with what you did, one line per finding (fixed in `<sha>`, or left and why).

Then start the next round on the new head commit. Stop when a round finds nothing, or
finds only things you have already left with a reason. That is the **final round**, and
its comment is the last review comment on the PR.

**At most 3 rounds per PR**, counting any rounds from section 5. If round 3 still has
findings, fix what you can, push, and stop reviewing. Post one last PR comment headed
`## Code review: round limit reached` that lists every finding still open. Say so in
`worker_done`. The orchestrator then hands the PR to the human. Do the same if a CI
or conflict fix would need a 4th round: push the fix and report the limit instead of
reviewing again.

## 5. Wait for CI and make it green

`gh pr checks <pr> --watch`. If a check fails, read its log, fix the cause, push, and watch
again. Do not report done while CI is failing or pending.

Any code change after the final round (a CI fix, a conflict resolution, a fix the
orchestrator asks for) needs another round of section 4 on the new head commit.
Edits that change no code, tests or config don't.

## 6. Report

Send `worker_done --outcome succeeded` with the PR number, the final CI result, the link
to the final round's PR comment, the finding count from each axis, and anything from the
ticket left undone.

## If you are stuck

A decision missing from the ticket and spec, a step only a human can take, or a conflict
with an ADR: `ask` the orchestrator, with exactly what you need and the options you see,
then end your turn. Orca wakes you with the answer. If the orchestrator tells you to stop,
push any useful work, open (or keep) the PR as a draft that references the ticket, and send
`worker_done --outcome failed` saying what is missing.
