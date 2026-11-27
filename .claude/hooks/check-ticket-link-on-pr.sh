#!/usr/bin/env bash
# PostToolUse hook (Bash): after `gh pr create`, `gh stack submit` or `gh stack add` in a ticket worktree, check the PR is
# linked in the ticket's Development field. Exit 2 feeds the problem back to the agent.
# Does nothing outside ticket worktrees (no `.ticket` marker at the worktree root).
set -uo pipefail

input="$(cat)"
cmd="$(jq -r '.tool_input.command // ""' <<<"$input")"
[[ "$cmd" == *"gh pr create"* || "$cmd" == *"gh stack submit"* || "$cmd" == *"gh stack add"* ]] || exit 0

cd "$(jq -r '.cwd // "."' <<<"$input")" 2>/dev/null || exit 0
root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
[ -f "$root/.ticket" ] || exit 0
n="$(tr -dc '0-9' < "$root/.ticket")"
[ -n "$n" ] || exit 0

if ! out="$("$root/scripts/check-ticket-link.sh" "$n" 2>&1)"; then
    echo "Ticket link check failed for #$n: $out" >&2
    echo "Fix this before reporting the ticket done." >&2
    exit 2
fi
exit 0
