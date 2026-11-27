# Shared by the ticket scripts (source it; do not run it). Sets the repo for every `gh`
# call (read from `gh repo view`), stops on a gh too old for these scripts, and holds the board and link helpers.
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
# The repo is whatever `gh repo view` says for the checkout (or $GH_REPO, if set), so a
# move to another owner needs no edit here. The board is the "Knowledge Pool" project of
# the engi-ai organization (project 1); `gh
# project` finds an organization or a user owner by itself. KP_BOARD_OWNER and
# KP_BOARD_NUMBER name another board.
BOARD_OWNER="${KP_BOARD_OWNER:-engi-ai}"
BOARD_NUMBER="${KP_BOARD_NUMBER:-1}"

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
    options="$(gh project field-list "$BOARD_NUMBER" --owner "$BOARD_OWNER" --format json \
        --jq '.fields[] | select(.name == "Status") | .options[].name')"
    match="$(grep -ixF "$status" <<<"$options" | head -n 1)" || true
    [ -n "$match" ] || die "The board (project #$BOARD_NUMBER) has no Status \"$status\"; \
add it in the board's settings first. Valid: $(paste -sd, <<<"$options" | sed 's/,/, /g')."
    echo "$match"
}
board_move() {
    local url="https://github.com/$GH_REPO/issues/$1" status
    status="$(board_check_status "$2")"
    gh project item-add "$BOARD_NUMBER" --owner "$BOARD_OWNER" --url "$url" >/dev/null
    gh project item-edit "$BOARD_NUMBER" --owner "$BOARD_OWNER" --url "$url" \
        --field Status --value "$status" >/dev/null
    echo "$status"
}

# linked_branches <issue>: the branches in the issue's Development field, one per line.
linked_branches() {
    gh api graphql -F owner="$REPO_OWNER" -F name="$REPO_NAME" -F n="$1" -f query='
      query($owner:String!,$name:String!,$n:Int!){ repository(owner:$owner,name:$name){
        issue(number:$n){ linkedBranches(first:50){ nodes{ ref{ name } } } } } }' \
      --jq '.data.repository.issue.linkedBranches.nodes[].ref.name'
}

# stack_top_branch <issue>: the branch at the top of the stack of the issue's parent spec,
# or nothing when the issue has no parent or its siblings have no open branch. A stack is
# the open sibling tickets' branches (linked branches and open PR heads, not branches whose
# PR is merged); the top is the one no open PR is based on. When two branches have nothing to order them (a started
# sibling that has no PR yet), it fails: wait for that PR rather than guess.
stack_top_branch() {
    local tops
    tops="$(gh api graphql -F owner="$REPO_OWNER" -F name="$REPO_NAME" -F n="$1" -f query='
      query($owner:String!,$name:String!,$n:Int!){ repository(owner:$owner,name:$name){
        issue(number:$n){ parent{ subIssues(first:100){ nodes{ number state
          linkedBranches(first:20){ nodes{ ref{ name } } }
          closedByPullRequestsReferences(first:10, includeClosedPrs:true){ nodes{ headRefName baseRefName state } }
        } } } } } }' \
      | jq -r --argjson n "$1" '
          [.data.repository.issue.parent.subIssues.nodes // [] | .[]
           | select(.number != $n and .state == "OPEN")] as $sib
          | [$sib[].closedByPullRequestsReferences.nodes[] | select(.state == "OPEN")] as $prs
          | ([$prs[].headRefName] + [$sib[].linkedBranches.nodes[].ref.name] | unique) as $branches
          | ([$sib[].closedByPullRequestsReferences.nodes[] | select(.state == "MERGED") | .headRefName]) as $merged
          | ($branches - $merged - [$prs[].baseRefName])[]')"
    [ "$(grep -c . <<<"$tops")" -le 1 ] \
        || die "Cannot tell the top of the spec's stack for #$1: $(paste -sd, <<<"$tops") are all unbased: a ticket of the spec is started but has no PR yet (wait for it), or two of its PRs both target main (a human sorts out the stack)."
    echo "$tops"
}

# has_merge_queue [<branch>]: print true or false for whether the branch (default main) has a
# merge queue. Call it as `queue="$(has_merge_queue)"`, not in an `&&` list: a failing
# lookup must stop the script, not read as "no queue".
has_merge_queue() {
    local id
    id="$(gh api graphql -F owner="$REPO_OWNER" -F name="$REPO_NAME" -F branch="${1:-main}" -f query='
      query($owner:String!,$name:String!,$branch:String!){ repository(owner:$owner,name:$name){
        mergeQueue(branch:$branch){ id } } }' --jq '.data.repository.mergeQueue.id // empty')"
    [ -n "$id" ] && echo true || echo false
}

require_gh
GH_REPO="${GH_REPO:-$(gh repo view --json owner,name --jq '.owner.login + "/" + .name')}" \
    || die "Cannot tell which repo this is: run from the checkout, or set GH_REPO=<owner>/<name>."
export GH_REPO   # every `gh` subcommand targets this repo
REPO_OWNER="${GH_REPO%%/*}"
REPO_NAME="${GH_REPO#*/}"
