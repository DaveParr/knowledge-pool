#!/usr/bin/env bash
# Move an issue's card on the "Knowledge Pool" GitHub Project board (project #7).
#
#   scripts/board.sh <issue-number> <status>
#
# <status> is any option of the board's Status field, fetched from GitHub at run time
# (case-insensitive; "-" and "_" read as spaces, so "in-progress" matches "In progress").
# Uses `gh api graphql` for the lookups because bare `gh issue view` fails here with the
# Projects (classic) deprecation error.
set -euo pipefail

REPO_OWNER="DaveParr"
REPO_NAME="knowledge-pool"
PROJECT_ID="PVT_kwHOAH-e384Boo56"
STATUS_FIELD_NAME="Status"

if [ "$#" -ne 2 ]; then
    echo "usage: scripts/board.sh <issue-number> <status>" >&2
    echo "status: any option of the board's $STATUS_FIELD_NAME field" >&2
    exit 2
fi

issue="$1"
case "$issue" in
    '' | *[!0-9]*) echo "issue number must be numeric, got: $issue" >&2; exit 2 ;;
esac

normalise() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr '_-' '  '; }

# One TSV line per option: <field id> <option id> <option name>
options="$(gh api graphql -F id="$PROJECT_ID" -F field="$STATUS_FIELD_NAME" \
    -f query='query($id: ID!, $field: String!) {
      node(id: $id) {
        ... on ProjectV2 {
          field(name: $field) {
            ... on ProjectV2SingleSelectField { id options { id name } }
          }
        }
      }
    }' \
    --jq '.data.node.field | select(.options != null) | .id as $f | .options[] | [$f, .id, .name] | @tsv')"

if [ -z "$options" ]; then
    echo "could not read the $STATUS_FIELD_NAME options of project $PROJECT_ID" >&2
    exit 1
fi

want="$(normalise "$2")"
field_id="" option="" status="" valid=""
while IFS=$'\t' read -r f id name; do
    valid="${valid:+$valid, }$name"
    if [ -z "$option" ] && [ "$(normalise "$name")" = "$want" ]; then
        field_id="$f"; option="$id"; status="$name"
    fi
done <<< "$options"

if [ -z "$option" ]; then
    echo "unknown status: $2" >&2
    echo "valid statuses: $valid" >&2
    exit 2
fi

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
    --field-id "$field_id" --single-select-option-id "$option" >/dev/null
echo "#$issue -> $status"
