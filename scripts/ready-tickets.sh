#!/usr/bin/env bash
# Print the numbers of tickets an agent may start now, lowest first, one per line.
#
#   scripts/ready-tickets.sh
#
# A ticket is ready when it is open, labelled `ready-for-agent`, unassigned, has no open
# blocker, and has no sub-issues (specs and maps have sub-issues; they are not tickets).
# Prints nothing (exit 0) when no ticket is ready. One GraphQL read, not the search API,
# so a label set a moment ago is already seen.
set -euo pipefail
source "$(dirname "$0")/lib/gh.sh"

gh api graphql --paginate -F owner="$REPO_OWNER" -F name="$REPO_NAME" -f query='
  query($owner:String!,$name:String!,$endCursor:String){ repository(owner:$owner,name:$name){
    issues(first:100, after:$endCursor, states:OPEN, labels:["ready-for-agent"]){
      nodes{ number assignees{ totalCount } subIssuesSummary{ total }
             issueDependenciesSummary{ blockedBy } }
      pageInfo{ hasNextPage endCursor } } } }' \
  --jq '.data.repository.issues.nodes[]
        | select(.assignees.totalCount == 0 and .subIssuesSummary.total == 0
                 and .issueDependenciesSummary.blockedBy == 0) | .number' \
| sort -n
