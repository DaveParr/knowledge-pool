#!/usr/bin/env bash
# Set an issue's Status on the "Knowledge Pool" board (project #7), adding its card first
# if it has none.
#
#   scripts/board.sh <issue-number> <status>
#
# <status> is any option of the board's Status field (case-insensitive; "-" and "_" read
# as spaces, so "in-progress" matches "In progress"). An unknown status fails and lists
# the valid ones.
set -euo pipefail
source "$(dirname "$0")/lib/gh.sh"

[ "$#" -eq 2 ] && is_number "$1" || usage "scripts/board.sh <issue-number> <status>"
status="$(board_move "$1" "$2")"
echo "#$1 -> $status"
