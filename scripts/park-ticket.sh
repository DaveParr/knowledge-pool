#!/usr/bin/env bash
# Hand a ticket back to the humans because it needs a decision first.
#
#   scripts/park-ticket.sh <issue-number> <comment-file>
#
# Swaps `ready-for-agent` for `needs-info` and unassigns @me (first, so a missing label
# fails before anything changes), comments <comment-file> (what is needed, exactly) on the
# ticket, and moves its card to Backlog.
set -euo pipefail
source "$(dirname "$0")/lib/gh.sh"

n="${1:-}" file="${2:-}"
is_number "$n" && [ -s "$file" ] || usage "scripts/park-ticket.sh <issue-number> <comment-file>"

gh issue edit "$n" --remove-label ready-for-agent --add-label needs-info --remove-assignee @me >/dev/null
gh issue comment "$n" --body-file "$file" >/dev/null
board_move "$n" Backlog
echo "#$n parked: needs-info, Backlog"
