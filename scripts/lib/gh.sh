# Shared by the ticket scripts (source it; do not run it). Sets the repo for every `gh`
# call, stops on a gh too old for these scripts, and holds the board and link helpers.
#
# Why gh >= 2.97.0: 2.97.0 is the first release whose `gh project item-edit` takes the
# field and option by name (`--field Status --value "In progress"`), which `board_move`
# relies on. It also carries 2.82.1's fix that stopped `gh pr view`/`gh pr edit` asking
# for Projects (classic) data, which GitHub now refuses, and four security fixes.
#
# `gh api graphql` exits 1 when a reply carries `errors`, even next to `data`, so
# `set -e` in the caller is enough to fail loudly on a partial GraphQL reply.

shopt -s inherit_errexit   # `die` inside $(...) stops the script, not just the subshell

GH_MIN_VERSION="2.97.0"
REPO_OWNER="DaveParr"
REPO_NAME="knowledge-pool"
export GH_REPO="$REPO_OWNER/$REPO_NAME"   # every `gh` subcommand targets this repo
BOARD_NUMBER=7                             # the "Knowledge Pool" user project

die() { echo "$*" >&2; exit 1; }
usage() { echo "usage: $*" >&2; exit 2; }
is_number() { case "${1:-}" in '' | *[!0-9]*) return 1 ;; esac; }

require_gh() {
    local have
    have="$(gh --version 2>/dev/null | sed -nE '1s/^gh version ([0-9.]+).*/\1/p')"
    [ -n "$have" ] || die "gh is not installed or not on PATH; these scripts need gh >= $GH_MIN_VERSION."
    if [ "$(printf '%s\n%s\n' "$GH_MIN_VERSION" "$have" | sort -V | head -n 1)" != "$GH_MIN_VERSION" ]; then
        die "gh $have is too old: these scripts need gh >= $GH_MIN_VERSION (upgrade with 'brew upgrade gh')."
    fi
}

# board_check_status <status>: print the board's own spelling of that Status option, or
# fail naming the valid ones.
# board_move <issue> <status>: put the issue on the board if it is not there yet, then set
# its Status. <status> is a Status option, in any case; "-" and "_" read as spaces. It
# checks the option exists before touching the board, and fails naming the valid ones: add
# a missing option in the board's settings, never through the API (replacing a
# single-select field's options can clear every card's Status). `item-add` returns the
# existing item when the issue is already on the board, so this never makes a second card.
board_check_status() {
    local status="${1//[-_]/ }" options match
    options="$(gh project field-list "$BOARD_NUMBER" --owner "$REPO_OWNER" --format json \
        --jq '.fields[] | select(.name == "Status") | .options[].name')"
    match="$(grep -ixF "$status" <<<"$options" | head -n 1)" || true
    [ -n "$match" ] || die "The board (project #$BOARD_NUMBER) has no Status \"$status\"; \
add it in the board's settings first. Valid: $(paste -sd, <<<"$options" | sed 's/,/, /g')."
    echo "$match"
}
board_move() {
    local url="https://github.com/$GH_REPO/issues/$1" status
    status="$(board_check_status "$2")"
    gh project item-add "$BOARD_NUMBER" --owner "$REPO_OWNER" --url "$url" >/dev/null
    gh project item-edit "$BOARD_NUMBER" --owner "$REPO_OWNER" --url "$url" \
        --field Status --value "$status" >/dev/null
    echo "$status"
}

# board_check_date_field <field>: fail unless the board has a date field by that exact
# name, naming the ones it has.
# board_date_get <issue> <field>: print the issue's <field> date on the board (YYYY-MM-DD,
# or nothing when unset). Fails if the board has no such date field or the issue no card.
# board_date <issue> <field> <YYYY-MM-DD>: set that date on the issue's card. <field> is a
# date field of the board, by its exact name ("Start date", "Target date"). Checks the date,
# the field and the card before writing, and never adds a card: a ticket gets its card when
# it is claimed (board_move), so a missing card means something else went wrong.
# board_target_date <issue> <timestamp>: set "Target date" to the day of a GitHub timestamp
# (ISO 8601, always UTC: the date is the part before the "T").
board_check_date_field() {
    local fields
    fields="$(gh api graphql -F owner="$REPO_OWNER" -F number="$BOARD_NUMBER" -f query='
      query($owner:String!,$number:Int!){ user(login:$owner){ projectV2(number:$number){
        fields(first:100){ nodes{ ... on ProjectV2Field{ name dataType } } } } } }' \
      --jq '.data.user.projectV2.fields.nodes[] | select(.dataType == "DATE") | .name')"
    grep -qxF "$1" <<<"$fields" || die "The board (project #$BOARD_NUMBER) has no date field \"$1\". \
Date fields: $(paste -sd, <<<"$fields" | sed 's/,/, /g')."
}
board_date_get() {
    local items
    board_check_date_field "$2"
    # One line "card <date>" per card, so a card with no date differs from no card at all.
    items="$(gh api graphql -F owner="$REPO_OWNER" -F name="$REPO_NAME" -F n="$1" -F field="$2" -f query='
      query($owner:String!,$name:String!,$n:Int!,$field:String!){ repository(owner:$owner,name:$name){
        issue(number:$n){ projectItems(first:50){ nodes{ project{ number owner{ ... on User{ login } } }
          fieldValueByName(name:$field){ ... on ProjectV2ItemFieldDateValue{ date } } } } } } }' \
      --jq ".data.repository.issue.projectItems.nodes[]
            | select(.project.number == $BOARD_NUMBER and .project.owner.login == \"$REPO_OWNER\")
            | \"card \" + (.fieldValueByName.date // \"\")")"
    [ -n "$items" ] || die "#$1 has no card on the board (project #$BOARD_NUMBER); add it with scripts/board.sh $1 <status>."
    items="$(head -n 1 <<<"$items")"
    echo "${items#card }"
}
board_date() {
    local url="https://github.com/$GH_REPO/issues/$1"
    [[ "$3" =~ ^[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$ ]] \
        || die "Not a date: \"$3\" (want YYYY-MM-DD)."
    board_date_get "$1" "$2" >/dev/null   # the field and the card exist
    gh project item-edit "$BOARD_NUMBER" --owner "$REPO_OWNER" --url "$url" \
        --field "$2" --date "$3" >/dev/null
}
board_target_date() {
    local day="${2%%T*}"
    board_date "$1" "Target date" "$day"
    echo "$day"
}

# linked_branches <issue>: the branches in the issue's Development field, one per line.
linked_branches() {
    gh api graphql -F owner="$REPO_OWNER" -F name="$REPO_NAME" -F n="$1" -f query='
      query($owner:String!,$name:String!,$n:Int!){ repository(owner:$owner,name:$name){
        issue(number:$n){ linkedBranches(first:50){ nodes{ ref{ name } } } } } }' \
      --jq '.data.repository.issue.linkedBranches.nodes[].ref.name'
}

require_gh
