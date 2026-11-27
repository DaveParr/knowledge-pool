#!/usr/bin/env bash
# Read a ticket PR's state and say what the ticket loop does next. Reads only.
#
#   scripts/pr-status.sh <pr-number>
#
# Prints one JSON object: the PR, its ticket, the review rounds, CI, the review-by-human
# labels, and `next` with a `reason`. `next` is the first of these that holds, in the
# order the ticket loop checks them:
#   merged       already merged (by the human, or an earlier run); `closed` likewise.
#   round-limit  3 `## Code review, round` comments, or a `## Code review: round limit
#                reached` comment: hand the PR to the human, never review again.
#   review       no review round, or the last one does not name the PR's head commit.
#   pr-body      the body does not follow the `/mattpocock-skills:pr` template (`## Summary`, `## Evidence`,
#                `## Merge Danger` with `**Door:**` and `**Blast Radius:**`), or its
#                `Describes: <sha>` line is missing or is not the head commit.
#   conflict     the PR conflicts with its base.
#   ci-failed    a check failed (`failing` lists them with links).
#   no-checks    the PR has no CI checks at all (`ci` is "none"): the workflow did not
#                start for it, so waiting will not help.
#   wait         CI is still running, or GitHub has not worked out mergeability yet.
#   blocked-by-lower
#                the PR is part of a stack and a PR below it is neither merged nor ready
#                (its own `next` is not `merge`): it waits for that one.
#   hold         a draft, a base that is neither main nor the branch of another PR (so
#                not a stack), or a `review-by-human` label on the PR, the ticket or the
#                ticket's parent spec: leave it for the human.
#   merge        none of the above: `scripts/merge-ticket.sh` may merge it. For a stacked
#                PR that means every PR below it is merged or ready too.
# A PR whose base is another PR's head branch belongs to a stack: `stack` gives its
# `position` (1 = bottom), the `lower` PRs bottom-first, each with the `next` pr-status
# gives it, and `lowerReady` (every lower PR is merged or `merge`).
# `responsesComplete` says every `## Code review, round <k>` has a `## Round <k> response`.
# Whether every finding in the last round was fixed or answered stays the reader's call.
set -euo pipefail
source "$(dirname "$0")/lib/gh.sh"

pr="${1:-}"
is_number "$pr" || usage "scripts/pr-status.sh <pr-number>"

info="$(gh pr view "$pr" --json number,url,state,isDraft,baseRefName,headRefOid,mergeable,labels,body,closingIssuesReferences,comments,statusCheckRollup)"

# The ticket: the PR body's `Ticket: #<n>` line, else the first issue the PR closes.
ticket="$(jq -r '((.body | capture("(?m)^Ticket: #(?<n>[0-9]+)").n) // .closingIssuesReferences[0].number) // empty' <<<"$info")"
[ -n "$ticket" ] || die "PR #$pr names no ticket: it closes no issue and has no 'Ticket: #<n>' line."

# The stack: while the base is not main, the PR below is the one whose head is that base.
# Each lower PR is read by this script itself (depth-limited), so `lower` holds what each
# one's `next` is. A base that no PR has as its head leaves the stack empty (and held).
stack='{"position":1,"lower":[],"lowerReady":true}'
base="$(jq -r .baseRefName <<<"$info")"
if [ "$base" != main ] && [ "${KP_STACK_DEPTH:-0}" -lt 20 ]; then
    below="$(gh pr list --head "$base" --state all --json number,state \
        | jq -r '[.[] | select(.state != "CLOSED")] | sort_by(.state != "OPEN") | .[0].number // empty')"
    if [ -n "$below" ]; then
        low="$(KP_STACK_DEPTH=$(( ${KP_STACK_DEPTH:-0} + 1 )) "$0" "$below" 2>/dev/null || echo '{}')"
        stack="$(jq -n --argjson low "$low" --argjson n "$below" '
          ($low.stack // {position: 1, lower: []}) as $s
          | {position: ($s.position + 1),
             lower: ($s.lower + [{pr: $n, ticket: $low.ticket, state: ($low.state // "UNKNOWN"),
                                  next: ($low.next // "unknown")}])}
          | .lowerReady = all(.lower[]; .next | IN("merge", "merged"))')"
    fi
fi

ticket_labels="$(gh api graphql -F owner="$REPO_OWNER" -F name="$REPO_NAME" -F n="$ticket" -f query='
  query($owner:String!,$name:String!,$n:Int!){ repository(owner:$owner,name:$name){ issue(number:$n){
    labels(first:50){ nodes{ name } } parent{ number labels(first:50){ nodes{ name } } } } } }' \
  --jq '.data.repository.issue | {ticket: [.labels.nodes[].name], parent: .parent.number,
        parentLabels: [(.parent.labels.nodes // [])[].name]}')"

jq --argjson t "$ticket" --argjson tl "$ticket_labels" --argjson stack "$stack" '
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
  | ([$rounds[] | capture("^## Code review, round (?<k>[0-9]+)").k]) as $round_numbers
  | ([.comments[].body | capture("^## Round (?<k>[0-9]+) response").k]) as $responded
  | (.body // "") as $body
  | [ {k: "## Summary", re: "(?m)^## Summary\\s*$"}, {k: "## Evidence", re: "(?m)^## Evidence\\s*$"},
      {k: "## Merge Danger", re: "(?m)^## Merge Danger\\s*$"},
      {k: "**Door:**", re: "\\*\\*Door:\\*\\*"}, {k: "**Blast Radius:**", re: "\\*\\*Blast Radius:\\*\\*"}
    | .re as $re | select($body | test($re) | not) | .k ] as $missing
  | ([$body | scan("Describes:\\**\\s*`?([0-9a-f]{7,40})")[0]] | last) as $describes
  | [.statusCheckRollup[] | {name: (.name // .context), bucket: bucket, link: (.detailsUrl // .targetUrl)}] as $checks
  | (if ($checks | length) == 0 then "none"
     elif any($checks[]; .bucket == "pending") then "pending"
     elif any($checks[]; .bucket == "fail") then "fail" else "pass" end) as $ci
  | [ (if any(.labels[]; .name == "review-by-human") then "PR #\(.number)" else empty end),
      (if ($tl.ticket | index("review-by-human")) then "ticket #\($t)" else empty end),
      (if ($tl.parentLabels | index("review-by-human")) then "parent #\($tl.parent)" else empty end)
    ] as $human
  | {pr: .number, url, state, ticket: $t, parent: $tl.parent, head: $head[0:7], headOid: $head,
     reviewRounds: ($rounds | length), lastRoundIsCurrent: $current,
     bodyMissing: $missing, bodyDescribes: $describes,
     responsesComplete: ($round_numbers | all(. as $k | $responded | index($k))),
     stack: $stack,
     draft: .isDraft, base: .baseRefName, mergeable, ci: $ci,
     failing: [$checks[] | select(.bucket == "fail")], reviewByHuman: $human}
  | . + (
      if .state != "OPEN" then {next: (.state | ascii_downcase), reason: "the PR is \(.state | ascii_downcase)"}
      elif .reviewRounds >= 3 or $limit_comment then {next: "round-limit", reason: "\(.reviewRounds) review rounds or a round-limit comment"}
      elif .reviewRounds == 0 then {next: "review", reason: "no review round on the PR"}
      elif (.lastRoundIsCurrent | not) then {next: "review", reason: "the last review round does not name head \(.head)"}
      elif (.bodyMissing | length) > 0 then {next: "pr-body", reason: "PR body lacks \(.bodyMissing | join(", ")): rewrite it with /mattpocock-skills:pr"}
      elif .bodyDescribes == null then {next: "pr-body", reason: "PR body has no Describes: <sha> line"}
      elif (.bodyDescribes as $d | .headOid | startswith($d) | not) then {next: "pr-body", reason: "PR body describes \(.bodyDescribes), head is \(.head)"}
      elif .mergeable == "CONFLICTING" then {next: "conflict", reason: "conflicts with \(.base)"}
      elif .ci == "fail" then {next: "ci-failed", reason: "failing: \([.failing[].name] | join(", "))"}
      elif .ci == "none" and (.draft | not) and (.reviewByHuman | length) == 0 then {next: "no-checks", reason: "the PR has no CI checks: the workflow did not start for it (base \(.base))"}
      elif .ci == "pending" then {next: "wait", reason: "CI is still running"}
      elif .mergeable == "UNKNOWN" then {next: "wait", reason: "GitHub has not worked out mergeability yet"}
      elif .draft then {next: "hold", reason: "draft PR"}
      elif (.stack.lowerReady | not) then
        ([.stack.lower[] | select(.next | IN("merge", "merged") | not)] | first) as $b
        | {next: "blocked-by-lower", reason: "waits for PR #\($b.pr) below it (its next: \($b.next))"}
      elif .base != "main" and (.stack.lower | length) == 0 then {next: "hold", reason: "base is \(.base), not main, and no PR has that branch as its head"}
      elif (.reviewByHuman | length) > 0 then {next: "hold", reason: "review-by-human on \(.reviewByHuman | join(", "))"}
      else {next: "merge", reason: "reviewed and described at head, CI green, no review-by-human label"} end)
' <<<"$info"
