#!/usr/bin/env bash
# Set a ticket's "Target date" on the board to the day (UTC) its work ended.
#
#   scripts/target-date.sh <issue-number> [<merged-pr-number>]
#
# Given a merged PR, that is its merge date, whether or not the merge closed the ticket.
# Otherwise the ticket must be closed: if a merged PR closed it, that PR's merge date (the
# latest one, should it have been reopened since); if not, its close date. Fails, changing
# nothing, if the PR is not merged, the ticket is open with no PR given, or it has no card.
# `scripts/merge-ticket.sh` sets it itself; run this when a human merged the PR or closed
# the ticket.
set -euo pipefail
source "$(dirname "$0")/lib/gh.sh"

n="${1:-}" pr="${2:-}"
{ [ "$#" -eq 1 ] || { [ "$#" -eq 2 ] && is_number "$pr"; }; } && is_number "$n" \
    || usage "scripts/target-date.sh <issue-number> [<merged-pr-number>]"

if [ -n "$pr" ]; then
    ended="$(gh pr view "$pr" --json mergedAt --jq '.mergedAt // ""')"
    [ -n "$ended" ] || die "PR #$pr is not merged."
else
    ended="$(gh api graphql -F owner="$REPO_OWNER" -F name="$REPO_NAME" -F n="$n" -f query='
      query($owner:String!,$name:String!,$n:Int!){ repository(owner:$owner,name:$name){
        issue(number:$n){ state closedAt timelineItems(itemTypes:CLOSED_EVENT,last:100){ nodes{
          ... on ClosedEvent{ closer{ ... on PullRequest{ mergedAt } } } } } } } }' \
      --jq '.data.repository.issue | select(.state == "CLOSED")
            | ([.timelineItems.nodes[].closer.mergedAt // empty] | last) // .closedAt')"
    [ -n "$ended" ] || die "#$n is still open; give its merged PR, or set the Target date once it closes."
fi
target="$(board_target_date "$n" "$ended")"
echo "#$n Target date -> $target"
