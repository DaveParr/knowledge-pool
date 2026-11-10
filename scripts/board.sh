#!/usr/bin/env bash
# Move an issue's card on the "Knowledge Pool" GitHub Project board (project #7).
#
#   scripts/board.sh <issue-number> <status>
#
# <status>: Backlog | Ready | In progress | In review | Done (case-insensitive;
# "in-progress" / "in-review" accepted). Uses `gh api graphql` for the lookup because
# bare `gh issue view` fails here with the Projects (classic) deprecation error.
set -euo pipefail

REPO_OWNER="DaveParr"
REPO_NAME="knowledge-pool"
PROJECT_ID="PVT_kwHOAH-e384Boo56"
STATUS_FIELD_ID="PVTSSF_lAHOAH-e384Boo56zhnIDMM"
OPT_BACKLOG="f75ad846"
OPT_READY="61e4505c"
OPT_IN_PROGRESS="47fc9ee4"
OPT_IN_REVIEW="df73e18b"
OPT_DONE="98236657"
VALID="Backlog, Ready, In progress, In review, Done"

if [ "$#" -ne 2 ]; then
    echo "usage: scripts/board.sh <issue-number> <status>" >&2
    echo "status: $VALID" >&2
    exit 2
fi

issue="$1"
case "$issue" in
    '' | *[!0-9]*) echo "issue number must be numeric, got: $issue" >&2; exit 2 ;;
esac

norm="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]' | tr '_-' '  ')"
case "$norm" in
    backlog) status="Backlog"; option="$OPT_BACKLOG" ;;
    ready) status="Ready"; option="$OPT_READY" ;;
    "in progress") status="In progress"; option="$OPT_IN_PROGRESS" ;;
    "in review") status="In review"; option="$OPT_IN_REVIEW" ;;
    done) status="Done"; option="$OPT_DONE" ;;
    *)
        echo "unknown status: $2" >&2
        echo "valid statuses: $VALID" >&2
        exit 2
        ;;
esac

item="$(gh api graphql \
    -F owner="$REPO_OWNER" -F name="$REPO_NAME" -F number="$issue" \
    -f query='query($owner: String!, $name: String!, $number: Int!) {
      repository(owner: $owner, name: $name) {
        issueOrPullRequest(number: $number) {
          ... on Issue { projectItems(first: 20) { nodes { id project { id } } } }
          ... on PullRequest { projectItems(first: 20) { nodes { id project { id } } } }
        }
      }
    }' \
    --jq ".data.repository.issueOrPullRequest.projectItems.nodes[]? | select(.project.id == \"$PROJECT_ID\") | .id" \
    | head -n 1)"

if [ -z "$item" ]; then
    echo "#$issue is not on the Knowledge Pool board" >&2
    exit 1
fi

gh project item-edit --id "$item" --project-id "$PROJECT_ID" \
    --field-id "$STATUS_FIELD_ID" --single-select-option-id "$option" >/dev/null
echo "#$issue -> $status"
