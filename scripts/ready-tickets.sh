#!/usr/bin/env bash
# Print the numbers of tickets an agent may start now, lowest first, one per line.
#
#   scripts/ready-tickets.sh
#
# A ticket is ready when it is open, labelled `ready-for-agent`, unassigned, has no open
# blocker, and has no sub-issues (specs and maps have sub-issues; they are not tickets).
# Prints nothing (exit 0) when no ticket is ready.
set -euo pipefail

REPO="DaveParr/knowledge-pool"

gh issue list -R "$REPO" --label ready-for-agent --state open --json number,assignees -L 200 \
    --jq '.[] | select(.assignees | length == 0) | .number' \
| sort -n \
| while read -r n; do
    gh api "repos/$REPO/issues/$n" \
        --jq 'select(.issue_dependencies_summary.blocked_by == 0 and (.sub_issues_summary.total // 0) == 0) | .number'
done
