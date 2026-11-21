#!/usr/bin/env bash
# Verify a ticket's PR is linked in the issue's Development field.
#
#   scripts/check-ticket-link.sh <issue-number> [<branch>]
#
# <branch> defaults to the current git branch. Passes (exit 0, prints the PR number) when
# an open PR from that branch exists, its body names the ticket (`Ticket: #<n>`), and it
# is in the issue's Development field, which means either:
#   - the PR is linked to the issue (it is in the PR's closing issue references). GitHub
#     does this itself when a PR from a linked branch opens into the default branch (main),
#     and drops the branch from the issue's linked branches at the same moment; or
#   - the branch is still one of the issue's linked branches (a PR into any other base).
# A missing `Ticket: #<n>` line is added to the PR body. Anything else fails with exit 1
# and says what is wrong.
#
# Uses REST/GraphQL directly: `gh pr edit` fails in this repo with the Projects (classic)
# deprecation error.
set -euo pipefail

OWNER="DaveParr"; NAME="knowledge-pool"; REPO="$OWNER/$NAME"

n="${1:-}"
case "$n" in '' | *[!0-9]*) echo "usage: scripts/check-ticket-link.sh <issue-number> [<branch>]" >&2; exit 2 ;; esac
branch="${2:-$(git branch --show-current)}"

pr="$(gh api "repos/$REPO/pulls?head=$OWNER:$branch&state=open" --jq '.[0] // empty')"
if [ -z "$pr" ]; then
    echo "No open PR from '$branch'." >&2; exit 1
fi
pr_num="$(jq -r .number <<<"$pr")"

links="$(gh api graphql -F owner="$OWNER" -F name="$NAME" -F n="$n" -F pr="$pr_num" -f query='
  query($owner:String!,$name:String!,$n:Int!,$pr:Int!){ repository(owner:$owner,name:$name){
    issue(number:$n){ linkedBranches(first:50){ nodes{ ref{ name } } } }
    pullRequest(number:$pr){ closingIssuesReferences(first:50){ nodes{ number } } } } }')"
linked="$(jq -r '.data.repository.issue.linkedBranches.nodes[].ref.name' <<<"$links")"
closes="$(jq -r '.data.repository.pullRequest.closingIssuesReferences.nodes[].number' <<<"$links")"
if ! grep -qxF "$n" <<<"$closes" && ! grep -qxF "$branch" <<<"$linked"; then
    echo "PR #$pr_num from '$branch' is not in issue #$n's Development field: the PR is not linked to the issue and the branch is not one of its linked branches." >&2
    linked="${linked//$'\n'/, }"
    echo "Linked branches: ${linked:-none}. Open the PR from the branch scripts/start-ticket.sh linked." >&2
    exit 1
fi

body="$(jq -r '.body // ""' <<<"$pr")"
if ! grep -qE "^Ticket: #$n\b" <<<"$body"; then
    gh api -X PATCH "repos/$REPO/pulls/$pr_num" -f body="Ticket: #$n"$'\n\n'"$body" >/dev/null
fi
echo "$pr_num"
