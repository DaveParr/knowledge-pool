#!/usr/bin/env bash
# Verify a ticket's PR is linked in the issue's Development field.
#
#   scripts/check-ticket-link.sh <issue-number> [<branch>]
#
# <branch> defaults to the current git branch. Passes (exit 0, prints the PR number) when:
#   - the branch is one of the issue's linked branches (this is what fills Development), and
#   - an open PR from that branch exists, and its body names the ticket (`Ticket: #<n>`).
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

linked="$(gh api graphql -F owner="$OWNER" -F name="$NAME" -F n="$n" -f query='
  query($owner:String!,$name:String!,$n:Int!){ repository(owner:$owner,name:$name){ issue(number:$n){
    linkedBranches(first:50){ nodes{ ref{ name } } } } } }' \
  --jq '.data.repository.issue.linkedBranches.nodes[].ref.name')"
if ! grep -qxF "$branch" <<<"$linked"; then
    echo "Branch '$branch' is not linked to issue #$n, so the PR will not show in its Development field." >&2
    echo "Linked branches: ${linked:-none}. Push the work to a linked branch (scripts/start-ticket.sh creates one) and open the PR from it." >&2
    exit 1
fi

pr="$(gh api "repos/$REPO/pulls?head=$OWNER:$branch&state=open" --jq '.[0] // empty')"
if [ -z "$pr" ]; then
    echo "No open PR from '$branch'." >&2; exit 1
fi
pr_num="$(jq -r .number <<<"$pr")"
body="$(jq -r '.body // ""' <<<"$pr")"
if ! grep -qE "^Ticket: #$n\b" <<<"$body"; then
    gh api -X PATCH "repos/$REPO/pulls/$pr_num" -f body="Ticket: #$n"$'\n\n'"$body" >/dev/null
fi
echo "$pr_num"
