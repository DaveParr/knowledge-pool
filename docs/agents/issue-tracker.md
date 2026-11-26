# Issue tracker: GitHub

Issues and specs for this repo are GitHub issues in `DaveParr/knowledge-pool`, and most work is prepared on the **Knowledge Pool** GitHub Project board (user project #7). Use the `gh` CLI for everything.

## Conventions

- **Create an issue**: `gh issue create --title "..." --body-file <file>`. Write multi-line bodies to a file first.
- **Read an issue**: `gh issue view <number> --json title,body,labels,comments,state`. Prefer `--json` for anything a script or agent parses.
- **List issues**: `gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'`, with `--label` and `--state` filters as needed.
- **Comment on an issue**: `gh issue comment <number> --body-file <file>`
- **Apply or remove labels**: `gh issue edit <number> --add-label "..."` or `--remove-label "..."`
- **Close**: `gh issue close <number> --comment "..."`
- **Update a PR body**: `gh pr edit <n> --body-file <file>`

`gh` infers the repo from `git remote -v` when it runs inside a clone.

## The project board

Work moves through the board's Status column. Its options, with the meanings the board gives them:

| Status | Meaning |
| --- | --- |
| **Backlog** | Not started, and nobody is preparing it yet. |
| **Designing** | Being prepared: the spec or ticket is still being written or decided. |
| **Ready** | Ready to be picked up. |
| **In progress** | Claimed; work has started. |
| **Blocked** | Work started, then stopped because it needs a human, before its PR opened. |
| **In review** | Its PR is open. This includes waiting on a human: a `review-by-human` hold, a High-risk ticket waiting for approval, or the review round limit. |
| **Done** | Closed. |

- **Add a new issue to the board**: `gh project item-add 7 --owner DaveParr --url <issue url>`. Every map, ticket and spec belongs on the board.
- **Set its status**: `scripts/board.sh <issue> <status>`, which also adds the card if it is missing. The board's workflows move a card to **Done** when its issue closes, and close an issue whose card is set to Done.
- **Choosing a status**: a ticket that is fully prepared goes in **Ready**, even while it waits on another issue. Its native "blocked by" dependency is what stops work starting (`scripts/ready-tickets.sh` skips any ticket with an open blocker), so it does not need to move when the blocker closes. Move a card to **In progress** when you claim it, to **In review** when its PR is open, and to **Done** when it closes.
- **Once work has started**, a ticket moves from **In progress** only to **Blocked** or **In review**, and never back to **Backlog** or **Designing**. It goes to **Blocked** when it needs a human before its PR opens: it is parked for a decision (`needs-info`), and goes back to **Ready** once it is answered and relabelled `ready-for-agent`. Once its PR is open, a ticket that needs a human stays in **In review**.
- **Risk** (Low, Medium, High) is a board field set when a ticket is estimated. The orchestrator does not merge a High-risk ticket's PR until a human says it can go in. Size and Priority are board fields too.
- **Triage labels and board status sit side by side.** A label says what kind of work an issue is (for example `ready-for-agent`); its board status says where that work has got to.

## Pull requests as a triage surface

**PRs as a request surface: no.** _(Set this to `yes` if this repo treats external PRs as feature requests. `/triage` reads this flag.)_

When it is set to `yes`, PRs go through the same labels and states as issues, using the `gh pr` equivalents:

- **Read a PR**: `gh pr view <number> --json title,body,labels,comments`, and `gh pr diff <number>` for the diff.
- **List external PRs for triage**: `gh pr list --state open --json number,title,body,labels,author,authorAssociation,comments`, then keep only those whose `authorAssociation` is `CONTRIBUTOR`, `FIRST_TIME_CONTRIBUTOR` or `NONE` (drop `OWNER`, `MEMBER` and `COLLABORATOR`).
- **Comment, label or close**: `gh pr comment`, `gh pr edit --add-label` or `--remove-label`, `gh pr close`.

Issues and PRs share one number space on GitHub, so a bare `#42` may be either. Try `gh pr view 42` first, and fall back to `gh issue view 42 --json ...`.

## When a skill says "publish to the issue tracker"

Create a GitHub issue, add it to the board, and set its status: Ready if it is fully prepared (an open blocker does not change that), Designing if it still needs decisions, Backlog if nobody is preparing it yet.

## When a skill says "fetch the relevant ticket"

Run `gh issue view <number> --json title,body,labels,comments,state`.

## Wayfinding operations

Used by `/wayfinder`. The **map** is a single issue, and its **child** issues are the tickets. All of them go on the board.

- **Map**: one issue labelled `wayfinder:map`, holding the Notes, Decisions so far and Fog sections. Create it with `gh issue create --label wayfinder:map`.
- **Child ticket**: an issue linked to the map as a GitHub sub-issue (`gh api` on the sub-issues endpoint). Where sub-issues aren't enabled, add the child to a task list in the map body and put `Part of #<map>` at the top of the child body. Labels: `wayfinder:<type>` (`research`, `prototype`, `grilling` or `task`). Once claimed, the ticket is assigned to the driving dev.
- **Blocking**: use GitHub's **native issue dependencies**, which show in the UI. Add an edge with `gh api --method POST repos/<owner>/<repo>/issues/<child>/dependencies/blocked_by -F issue_id=<blocker-db-id>`. `<blocker-db-id>` is the blocker's numeric **database id** (`gh api repos/<owner>/<repo>/issues/<n> --jq .id`), not its `#number` or `node_id`. GitHub reports open blockers in `issue_dependencies_summary.blocked_by`, which is the live gate. Where dependencies aren't available, put a `Blocked by: #<n>, #<n>` line at the top of the child body instead. A ticket is unblocked when every blocker is closed. The dependency, not the board column, gates the work: a prepared ticket sits in Ready whether or not it has an open blocker. (The board's **Blocked** status is something else: started work that needs a human.)
- **Frontier query**: list the map's open children (`gh issue list --state open`, limited to the map's sub-issues or task list). Drop any with an open blocker (`issue_dependencies_summary.blocked_by > 0`, or an open issue in the `Blocked by` line) and any with an assignee. The first one left, in map order, is next.
- **Claim**: `gh issue edit <n> --add-assignee @me` is the session's first write. Then run `scripts/board.sh <n> "In progress"`.
- **Resolve**: `gh issue comment <n> --body-file <file>` with the answer, then `gh issue close <n>`, then `scripts/board.sh <n> Done`. Finally, append a pointer (one-line gist and link) to the map's Decisions so far.
