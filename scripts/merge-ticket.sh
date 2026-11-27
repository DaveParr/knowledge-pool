#!/usr/bin/env bash
# Merge a ticket PR the orchestrator has decided to merge, and record that it did.
#
#   scripts/merge-ticket.sh <pr-number>
#
# Refuses (exit 1, nothing changed) unless `scripts/pr-status.sh` says `next: merge`, so a
# draft, a PR whose base is not main or the PR below it, red or running CI, a stale review,
# a PR whose lower PR is not ready, or a `review-by-human` label on the PR, its ticket or
# the parent spec is never merged here. Branches are never deleted.
#
# Two things pick how it merges:
#   stack  the PR sits on other open PRs of its spec's stack: `gh stack merge <pr> --yes`,
#          which lands the PRs below it too, all or none (GitHub retargets the next PR up
#          to main). Without a merge queue the method is a merge commit.
#   queue  main has a merge queue: the PR (or stack) is enqueued and GitHub merges it once
#          its combination with main is green. Nothing says "merged" yet: the ticket is not
#          closed and no "Merged" comment is made; the after-merge event does that.
#   (neither: a merge commit by `gh pr merge`, then the ticket is closed.)
# When the merge is direct: label `auto-merged` and comment why, on each PR landed. The PR
# is linked to its ticket, so GitHub closes the ticket on merge and the board's "Item
# closed" workflow moves its card to Done; a ticket still open afterwards is closed here.
set -euo pipefail
source "$(dirname "$0")/lib/gh.sh"

pr="${1:-}"
is_number "$pr" || usage "scripts/merge-ticket.sh <pr-number>"

status="$("$(dirname "$0")/pr-status.sh" "$pr")"
next="$(jq -r .next <<<"$status")"
[ "$next" = merge ] || die "Not merging PR #$pr: next is '$next' ($(jq -r .reason <<<"$status"))."
ticket="$(jq -r .ticket <<<"$status")"
base="$(jq -r .base <<<"$status")"
below="$(jq -r '[.stack.lower[] | select(.state == "OPEN")] | length' <<<"$status")"

queue=false
has_merge_queue main && queue=true

if [ "$queue" = true ]; then
    if [ "$below" -gt 0 ]; then
        gh stack merge "$pr" --yes
    else
        gh pr merge "$pr" --merge --match-head-commit "$(jq -r .headOid <<<"$status")"
    fi
    gh pr comment "$pr" --body "Added to the merge queue by the ticket orchestrator: reviewed at the head commit, CI passed, no review-by-human label. GitHub merges it when its combination with main is green." >/dev/null
    echo "queued #$pr; ticket #$ticket stays open until the merge"
    exit 0
fi

if [ "$below" -gt 0 ]; then
    gh stack merge "$pr" --yes --merge
else
    gh pr merge "$pr" --merge --match-head-commit "$(jq -r .headOid <<<"$status")"
fi

# Each PR landed: this one, and the open ones below it.
landed="$(jq -r '[(.stack.lower[] | select(.state == "OPEN") | [.pr, .ticket]), [.pr, .ticket]]
    | .[] | "\(.[0]) \(.[1])"' <<<"$status")"
while read -r landed_pr landed_ticket; do
    gh pr edit "$landed_pr" --add-label auto-merged >/dev/null
    gh pr comment "$landed_pr" --body "Merged automatically by the ticket orchestrator: reviewed at the head commit, CI passed, no review-by-human label on the ticket, its parent spec or the PR." >/dev/null
    if [ "$(gh issue view "$landed_ticket" --json state --jq .state)" = OPEN ]; then
        gh issue close "$landed_ticket" --reason completed --comment "Merged in #$landed_pr." >/dev/null
    fi
done <<<"$landed"
echo "merged #$pr (base $base); landed: $(awk '{printf "#%s ", $1}' <<<"$landed")"
