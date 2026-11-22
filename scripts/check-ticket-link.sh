#!/usr/bin/env bash
# Verify a ticket's PR is linked in the issue's Development field.
#
#   scripts/check-ticket-link.sh <issue-number> [<branch>]
#
# <branch> defaults to the current git branch. Passes (exit 0, prints the PR number) when
# an open PR from that branch exists, its body names the ticket (`Ticket: #<n>`), and it
# is in the issue's Development field, which means either:
#   - the PR is linked to the issue (it is in the PR's closing issue references). GitHub
#     does this itself when a PR from a linked branch opens into the default branch (main),
#     and drops the branch from the issue's linked branches at the same moment; or
#   - the branch is still one of the issue's linked branches (a PR into any other base).
# A missing `Ticket: #<n>` line is added to the PR body. Anything else fails with exit 1
# and says what is wrong.
set -euo pipefail
source "$(dirname "$0")/lib/gh.sh"

n="${1:-}"
is_number "$n" || usage "scripts/check-ticket-link.sh <issue-number> [<branch>]"
branch="${2:-$(git branch --show-current)}"

pr="$(gh pr list --head "$branch" --state open --json number --jq '.[0].number // empty')"
[ -n "$pr" ] || die "No open PR from '$branch'."

info="$(gh pr view "$pr" --json closingIssuesReferences,body)"
closes="$(jq -r '.closingIssuesReferences[].number' <<<"$info")"
if ! grep -qxF "$n" <<<"$closes"; then
    linked="$(linked_branches "$n")"
    grep -qxF "$branch" <<<"$linked" || die "PR #$pr from '$branch' is not in issue #$n's Development field: \
the PR is not linked to the issue and the branch is not one of its linked branches \
(linked branches: $(paste -sd, <<<"${linked:-none}")). Open the PR from the branch scripts/start-ticket.sh linked."
fi

body="$(jq -r .body <<<"$info")"
if ! grep -qE "^Ticket: #$n\b" <<<"$body"; then
    printf 'Ticket: #%s\n\n%s' "$n" "$body" | gh pr edit "$pr" --body-file - >/dev/null
fi
echo "$pr"
