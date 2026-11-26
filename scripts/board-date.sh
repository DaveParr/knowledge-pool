#!/usr/bin/env bash
# Read or set a date field on an issue's card on the "Knowledge Pool" board (project #7).
#
#   scripts/board-date.sh <issue-number> <field>                 # print it (empty if unset)
#   scripts/board-date.sh <issue-number> <field> <YYYY-MM-DD>    # set it
#
# <field> is a date field by its exact name: "Start date" or "Target date". Fails, changing
# nothing, if the date is malformed, the board has no such field, or the issue has no card.
set -euo pipefail
source "$(dirname "$0")/lib/gh.sh"

{ [ "$#" -eq 2 ] || [ "$#" -eq 3 ]; } && is_number "$1" \
    || usage "scripts/board-date.sh <issue-number> \"Start date\"|\"Target date\" [<YYYY-MM-DD>]"
if [ "$#" -eq 2 ]; then
    board_date_get "$1" "$2"
else
    board_date "$1" "$2" "$3"
    echo "#$1 $2 -> $3"
fi
