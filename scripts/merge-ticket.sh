#!/usr/bin/env bash
# Merge a ticket PR the orchestrator has decided to merge, and record that it did.
#
#   scripts/merge-ticket.sh <pr-number> [--approved]
#
# Refuses (exit 1, nothing changed) unless `scripts/pr-status.sh` says `next: merge`, so a
# draft, a PR into another base, red or running CI, a stale review, or a `review-by-human`
# label on the PR, its ticket or the parent spec is never merged here. A High-risk ticket's
# PR (`next: approve`) merges only with `--approved`, which the orchestrator passes once a
# human has told it the PR can go in; `--approved` never overrides anything else.
# Then: merge commit (the branch is kept), label `auto-merged` (unless approved), comment why. The PR is
# linked to its ticket, so GitHub closes the ticket on merge and the board's "Item closed"
# workflow moves its card to Done; if the ticket is still open afterwards (the PR reached it
# only through its branch), it is closed here. Last, the ticket's "Target date" on the board
# is set to the merge date (UTC).
set -euo pipefail
source "$(dirname "$0")/lib/gh.sh"

pr="${1:-}" approved="${2:-}"
is_number "$pr" && { [ "$#" -eq 1 ] || { [ "$#" -eq 2 ] && [ "$approved" = --approved ]; }; } \
    || usage "scripts/merge-ticket.sh <pr-number> [--approved]"

status="$("$(dirname "$0")/pr-status.sh" "$pr")"
next="$(jq -r .next <<<"$status")"
[ "$next" = merge ] || { [ "$next" = approve ] && [ -n "$approved" ]; } \
    || die "Not merging PR #$pr: next is '$next' ($(jq -r .reason <<<"$status"))."
ticket="$(jq -r .ticket <<<"$status")"

gh pr merge "$pr" --merge --match-head-commit "$(jq -r .headOid <<<"$status")"
if [ "$next" = approve ]; then
    gh pr comment "$pr" --body "Merged by the ticket orchestrator after a human approved it: ticket #$ticket is High risk. Reviewed at the head commit, CI passed, no review-by-human label." >/dev/null
else
    gh pr edit "$pr" --add-label auto-merged >/dev/null
    gh pr comment "$pr" --body "Merged automatically by the ticket orchestrator: reviewed at the head commit, CI passed, no review-by-human label on the ticket, its parent spec or the PR, and the ticket is not High risk." >/dev/null
fi

if [ "$(gh issue view "$ticket" --json state --jq .state)" = OPEN ]; then
    gh issue close "$ticket" --reason completed --comment "Merged in #$pr." >/dev/null
fi
target="$(board_target_date "$ticket" "$(gh pr view "$pr" --json mergedAt --jq .mergedAt)")"
echo "merged #$pr; ticket #$ticket closed, Target date $target"
