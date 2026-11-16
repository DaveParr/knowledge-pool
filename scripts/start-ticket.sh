#!/usr/bin/env bash
# Claim a ticket and give it its own Orca worktree on a branch linked to the issue.
#
#   scripts/start-ticket.sh <issue-number>
#
# Steps, in order:
#   1. Claim: assign @me and move the card to "In progress".
#   2. Create an Orca worktree `ticket-<n>` on branch `DaveParr/<n>-<slug>`, based on the
#      integration branch, with the issue linked in Orca's metadata. Orca adds a numeric
#      suffix if the branch name is taken, so the real name is read back from Orca.
#   3. `gh issue develop` creates that branch on GitHub as a linked branch, which puts it
#      in the issue's Development field. (A PR into a non-default branch never fills
#      Development from "Closes #n"; the linked branch is the only link that works here.)
#   4. Point the local branch at the linked remote branch and write the `.ticket` marker.
#
# Prints one JSON line: {"issue":n,"branch":"...","worktreeId":"...","path":"..."}.
# Start the worker afterwards with `orca orchestration worker-start --worktree issue:<n>`.
set -euo pipefail

REPO="DaveParr/knowledge-pool"
REPO_ID="d0c89184-5aee-4d56-91c1-4faa754134e8"   # Orca repo id for knowledge-pool
BASE="DaveParr/planning-deployment"
ORCA="${ORCA_CLI_COMMAND:-orca}"

n="${1:-}"
case "$n" in '' | *[!0-9]*) echo "usage: scripts/start-ticket.sh <issue-number>" >&2; exit 2 ;; esac
cd "$(git rev-parse --show-toplevel)"

title="$(gh api "repos/$REPO/issues/$n" --jq .title)"
slug="$(printf '%s' "$title" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+|-+$//g' | cut -c1-40 | sed -E 's/-+$//')"
want_branch="DaveParr/$n-${slug:-ticket}"

# 1. Claim
gh issue edit "$n" -R "$REPO" --add-assignee @me >/dev/null
scripts/board.sh "$n" "In progress" >&2

# 2. Worktree
git fetch -q origin "$BASE"
"$ORCA" worktree create --repo "id:$REPO_ID" --name "ticket-$n" --branch "$want_branch" \
    --base-branch "origin/$BASE" --issue "$n" --no-parent --json >/dev/null
wt="$("$ORCA" worktree list --repo "id:$REPO_ID" --json \
    | jq -c --arg n "$n" '[.result.worktrees[] | select((.linkedIssue|tostring) == $n and (.isArchived|not))] | max_by(.sortOrder)')"
if [ -z "$wt" ] || [ "$wt" = "null" ]; then
    echo "Orca created no worktree linked to #$n" >&2; exit 1
fi
path="$(jq -r .path <<<"$wt")"
wt_id="$(jq -r .id <<<"$wt")"
branch="$(jq -r .branch <<<"$wt")"; branch="${branch#refs/heads/}"

# 3. Linked branch on GitHub (fills the issue's Development field)
gh issue develop "$n" -R "$REPO" --name "$branch" --base "$BASE" >/dev/null

# 4. Track the linked branch, and mark the worktree as a ticket worktree
git -C "$path" fetch -q origin "$branch"
git -C "$path" branch -q --set-upstream-to "origin/$branch"
git -C "$path" reset -q --hard "origin/$branch"   # fresh worktree, nothing to lose
echo "$n" > "$path/.ticket"
exclude="$(git -C "$path" rev-parse --git-common-dir)/info/exclude"
grep -qx '.ticket' "$exclude" 2>/dev/null || echo '.ticket' >> "$exclude"

jq -cn --argjson issue "$n" --arg branch "$branch" --arg id "$wt_id" --arg path "$path" \
    '{issue:$issue, branch:$branch, worktreeId:$id, path:$path}'
