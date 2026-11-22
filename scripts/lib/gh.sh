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

# board_check_status <status>: fail unless the board's Status field has that option.
# board_move <issue> <status>: put the issue on the board if it is not there yet, then set
# its Status. <status> is a Status option, in any case; "-" and "_" read as spaces. It
# checks the option exists before touching the board, and fails naming the valid ones: add
# a missing option in the board's settings, never through the API (replacing a
# single-select field's options can clear every card's Status). `item-add` returns the
# existing item when the issue is already on the board, so this never makes a second card.
board_check_status() {
    local status="${1//[-_]/ }" options
    options="$(gh project field-list "$BOARD_NUMBER" --owner "$REPO_OWNER" --format json \
        --jq '.fields[] | select(.name == "Status") | .options[].name')"
    grep -qixF "$status" <<<"$options" || die "The board (project #$BOARD_NUMBER) has no Status \"$status\"; \
add it in the board's settings first. Valid: $(paste -sd, <<<"$options" | sed 's/,/, /g')."
}
board_move() {
    local url="https://github.com/$GH_REPO/issues/$1" status="${2//[-_]/ }"
    board_check_status "$status"
    gh project item-add "$BOARD_NUMBER" --owner "$REPO_OWNER" --url "$url" >/dev/null
    gh project item-edit "$BOARD_NUMBER" --owner "$REPO_OWNER" --url "$url" \
        --field Status --value "$status" >/dev/null
}

# linked_branches <issue>: the branches in the issue's Development field, one per line.
linked_branches() {
    gh api graphql -F owner="$REPO_OWNER" -F name="$REPO_NAME" -F n="$1" -f query='
      query($owner:String!,$name:String!,$n:Int!){ repository(owner:$owner,name:$name){
        issue(number:$n){ linkedBranches(first:50){ nodes{ ref{ name } } } } } }' \
      --jq '.data.repository.issue.linkedBranches.nodes[].ref.name'
}

require_gh
