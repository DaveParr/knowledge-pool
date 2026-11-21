#!/usr/bin/env bash
# Read a ticket PR's state and say what the orchestrator does next. Reads only.
#
#   scripts/pr-status.sh <pr-number>
#
# Prints one JSON object: the PR, its ticket, the review rounds, CI, the review-by-human
# labels, and `next` with a `reason`. `next` is the first of these that holds, in the
# order docs/agents/ticket-orchestrator.md checks them:
#   merged       already merged (by the human, or an earlier run); `closed` likewise.
#   round-limit  3 `## Code review, round` comments, or a `## Code review: round limit
#                reached` comment: hand the PR to the human, never review again.
#   review       no review round, or the last one does not name the PR's head commit.
#   conflict     the PR conflicts with its base.
#   ci-failed    a check failed (`failing` lists them with links).
#   wait         CI is still running, or GitHub has not worked out mergeability yet.
#   hold         a draft, a base other than main, or a `review-by-human` label on the
#                PR, the ticket or the ticket's parent spec: leave it for the human.
#   merge        none of the above: `scripts/merge-ticket.sh` may merge it.
# Whether every finding in the last round was fixed or answered stays the reader's call.
set -euo pipefail
source "$(dirname "$0")/lib/gh.sh"

pr="${1:-}"
is_number "$pr" || usage "scripts/pr-status.sh <pr-number>"

info="$(gh pr view "$pr" --json number,url,state,isDraft,baseRefName,headRefOid,mergeable,labels,body,closingIssuesReferences,comments,statusCheckRollup)"

# The ticket: the PR body's `Ticket: #<n>` line, else the first issue the PR closes.
ticket="$(jq -r '((.body | capture("(?m)^Ticket: #(?<n>[0-9]+)").n) // .closingIssuesReferences[0].number) // empty' <<<"$info")"
[ -n "$ticket" ] || die "PR #$pr names no ticket: it closes no issue and has no 'Ticket: #<n>' line."

ticket_labels="$(gh api graphql -F owner="$REPO_OWNER" -F name="$REPO_NAME" -F n="$ticket" -f query='
  query($owner:String!,$name:String!,$n:Int!){ repository(owner:$owner,name:$name){ issue(number:$n){
    labels(first:50){ nodes{ name } } parent{ number labels(first:50){ nodes{ name } } } } } }' \
  --jq '.data.repository.issue | {ticket: [.labels.nodes[].name], parent: .parent.number,
        parentLabels: [(.parent.labels.nodes // [])[].name]}')"

jq --argjson t "$ticket" --argjson tl "$ticket_labels" '
  def bucket:
    if .__typename == "CheckRun" then
      if .status != "COMPLETED" then "pending"
      elif (.conclusion | IN("SUCCESS", "NEUTRAL", "SKIPPED")) then "pass" else "fail" end
    else
      if (.state | IN("PENDING", "EXPECTED")) then "pending"
      elif .state == "SUCCESS" then "pass" else "fail" end
    end;
  .headRefOid as $head
  | [.comments[].body | select(startswith("## Code review, round"))] as $rounds
  | ($rounds[-1] // "" | [scan("\\b[0-9a-f]{7,40}\\b")] | any(. as $s | $head | startswith($s))) as $current
  | ([.comments[].body | select(startswith("## Code review: round limit reached"))] | length > 0) as $limit_comment
  | [.statusCheckRollup[] | {name: (.name // .context), bucket: bucket, link: (.detailsUrl // .targetUrl)}] as $checks
  | (if ($checks | length) == 0 or any($checks[]; .bucket == "pending") then "pending"
     elif any($checks[]; .bucket == "fail") then "fail" else "pass" end) as $ci
  | [ (if any(.labels[]; .name == "review-by-human") then "PR #\(.number)" else empty end),
      (if ($tl.ticket | index("review-by-human")) then "ticket #\($t)" else empty end),
      (if ($tl.parentLabels | index("review-by-human")) then "parent #\($tl.parent)" else empty end)
    ] as $human
  | {pr: .number, url, state, ticket: $t, parent: $tl.parent, head: $head[0:7], headOid: $head,
     reviewRounds: ($rounds | length), lastRoundIsCurrent: $current,
     draft: .isDraft, base: .baseRefName, mergeable, ci: $ci,
     failing: [$checks[] | select(.bucket == "fail")], reviewByHuman: $human}
  | . + (
      if .state != "OPEN" then {next: (.state | ascii_downcase), reason: "the PR is \(.state | ascii_downcase)"}
      elif .reviewRounds >= 3 or $limit_comment then {next: "round-limit", reason: "\(.reviewRounds) review rounds or a round-limit comment"}
      elif .reviewRounds == 0 then {next: "review", reason: "no review round on the PR"}
      elif (.lastRoundIsCurrent | not) then {next: "review", reason: "the last review round does not name head \(.head)"}
      elif .mergeable == "CONFLICTING" then {next: "conflict", reason: "conflicts with \(.base)"}
      elif .ci == "fail" then {next: "ci-failed", reason: "failing: \([.failing[].name] | join(", "))"}
      elif .ci == "pending" then {next: "wait", reason: "CI is still running"}
      elif .mergeable == "UNKNOWN" then {next: "wait", reason: "GitHub has not worked out mergeability yet"}
      elif .draft then {next: "hold", reason: "draft PR"}
      elif .base != "main" then {next: "hold", reason: "base is \(.base), not main"}
      elif (.reviewByHuman | length) > 0 then {next: "hold", reason: "review-by-human on \(.reviewByHuman | join(", "))"}
      else {next: "merge", reason: "reviewed at head, CI green, no review-by-human label"} end)
' <<<"$info"
