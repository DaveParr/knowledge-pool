---
name: qa-ticket
description: Set up and walk a human through manual QA of a ticket or PR in this repo. Use when the user says a ticket is "human qa", asks how to qa or prove work locally, or asks to set it up for them to qa.
disable-model-invocation: true
---

The human QAs by hand. Your job is to get the PR branch running, hand over a short script with pass conditions, and then handle what they find. Do the setup yourself; never just describe it.

1. **Find what to prove.** Read the ticket (`gh issue view <n> --json title,body,comments`), its PR, and the diff. Say in two or three lines what changed for a user.
2. **Run it for them.** In the PR's worktree (check the branch out if needed): `jac x check` once, then `jac x up` (see `run-knowledge-pool`). For anything the app needs to show, set the data up too: seed precons with `jac run --no-serve seed.jac` (`jac x up` never seeds), or `claude mcp add` the printed line (a new Claude session is needed before MCP tools load). Smoke it yourself first (`/healthz`, one real call, or `jac browse`) so the human never meets a dead app.
3. **Give a script, not a lecture.** Numbered steps, each with a pass condition, using the real URLs and ports from `jac x status`. Cover the happy path in the browser or the MCP client, then the edges the ticket names (refusals, empty states, reload keeps the data). Mention any decks already in the database so they are not a surprise. Say which steps are not reachable yet and why.
4. **Bugs they report.** Ask nothing first: reproduce, find the cause (`diagnosing-bugs` for hard ones), and say whether the PR caused it. Fix it on the same branch with a regression test that fails first, run `jac x check`, commit, push, restart the app, and tell them what to re-check. A bug the PR did not cause but that blocks QA is still fixed here; note it in the PR body.
5. **Setup problems** (a step they cannot do, a missing tool, a command that fails for them) are your bug: fix the setup and re-issue only the changed steps.
6. **On "lgtm" / "merge".** Confirm CI is green (`gh pr checks <n>`), then merge as the ticket loop does: `scripts/merge-ticket.sh <pr>`, which handles stacks and the merge queue (a direct merge closes the ticket, and the board's workflow moves its card to **Done**; with a queue it only enqueues, and the real merge closes it). Report what that unblocked on the board. Do these only when they say so.
7. When finished, `jac x down` and say what is still running.
