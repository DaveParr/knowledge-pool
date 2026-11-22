#!/usr/bin/env bash
# Hand a ticket back to the humans because it needs a decision first.
#
#   scripts/park-ticket.sh <issue-number> <comment-file>
#
# Swaps `ready-for-agent` for `needs-info` and unassigns @me (first, so a missing label
# fails before anything changes), comments <comment-file> (what is needed, exactly) on the
# ticket, and moves its card to Blocked (Backlog is for tickets still being prepared).
# The board's Status needs a "Blocked" option; this fails before changing anything if not.
# The card's Start date and Target date are left as they are.
# To unpark, a human answers, relabels it `ready-for-agent` and moves the card to Ready.
set -euo pipefail
source "$(dirname "$0")/lib/gh.sh"

n="${1:-}" file="${2:-}"
is_number "$n" && [ -s "$file" ] || usage "scripts/park-ticket.sh <issue-number> <comment-file>"

board_check_status Blocked >/dev/null
gh issue edit "$n" --remove-label ready-for-agent --add-label needs-info --remove-assignee @me >/dev/null
gh issue comment "$n" --body-file "$file" >/dev/null
board_move "$n" Blocked >/dev/null
echo "#$n parked: needs-info, Blocked"
