#!/usr/bin/env bash
# Set a closed ticket's "Target date" on the board to the day (UTC) its work ended.
#
#   scripts/target-date.sh <issue-number>
#
# If a merged PR closed the ticket, that is the PR's merge date (the latest such PR, should
# it have been reopened since); if no merged PR ever closed it, its close date. Fails, changing nothing, if the ticket is
# still open or has no card. `scripts/merge-ticket.sh` sets it itself; run this when a
# human merged the PR or closed the ticket.
set -euo pipefail
source "$(dirname "$0")/lib/gh.sh"

n="${1:-}"
[ "$#" -eq 1 ] && is_number "$n" || usage "scripts/target-date.sh <issue-number>"

ended="$(gh api graphql -F owner="$REPO_OWNER" -F name="$REPO_NAME" -F n="$n" -f query='
  query($owner:String!,$name:String!,$n:Int!){ repository(owner:$owner,name:$name){
    issue(number:$n){ state closedAt timelineItems(itemTypes:CLOSED_EVENT,last:100){ nodes{
      ... on ClosedEvent{ closer{ ... on PullRequest{ mergedAt } } } } } } } }' \
  --jq '.data.repository.issue | select(.state == "CLOSED")
        | ([.timelineItems.nodes[].closer.mergedAt // empty] | last) // .closedAt')"
[ -n "$ended" ] || die "#$n is still open; its Target date is set when it closes."
target="$(board_target_date "$n" "$ended")"
echo "#$n Target date -> $target"
