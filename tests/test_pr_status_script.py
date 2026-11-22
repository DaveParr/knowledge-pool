"""scripts/pr-status.sh and scripts/merge-ticket.sh: what the ticket orchestrator does next
with a ticket PR.

`gh` is a fake on PATH: `gh pr view` prints the PR JSON a test writes, `gh api graphql`
prints the ticket's labels (already in the shape the script's --jq makes), and every call
is logged, so these tests run offline."""

import json
import os
import stat
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
PR_STATUS = ROOT / "scripts" / "pr-status.sh"
MERGE_TICKET = ROOT / "scripts" / "merge-ticket.sh"

HEAD = "def5678" + "0" * 33
OLD = "abc1234" + "0" * 33

FAKE_GH = """#!/usr/bin/env bash
echo "gh $*" >> "$FAKE_LOG"
case "$1 $2" in
  "--version "*) echo "gh version 2.105.0 (2026-11-17)" ;;
  "pr view") cat "$FAKE_PR" ;;
  "api graphql") cat "$FAKE_TICKET" ;;
  *) echo "fake gh: unexpected: $*" >&2; exit 1 ;;
esac
"""


def body(describes=HEAD[:7], drop=()):
    parts = {
        "ticket": "Ticket: #42",
        "summary": "## Summary\n\nA change.",
        "evidence": f"## Evidence\n\n- **Before:** x\n  **After:** y\n\nDescribes: `{describes}`"
        if describes
        else "## Evidence\n\n- **Before:** x\n  **After:** y",
        "danger": "## Merge Danger\n\n**Door:** two-way\n\n**Blast Radius:** orchestrator",
    }
    return "\n\n".join(v for k, v in parts.items() if k not in drop)


def review(sha):
    return {"body": f"## Code review, round 1\n\nReviewed head `{sha[:7]}`.\n\n## Standards\n\nNone."}


def pr(**over):
    base = {
        "number": 7,
        "url": "https://github.com/DaveParr/knowledge-pool/pull/7",
        "state": "OPEN",
        "isDraft": False,
        "baseRefName": "main",
        "headRefOid": HEAD,
        "mergeable": "MERGEABLE",
        "labels": [],
        "body": body(),
        "closingIssuesReferences": [{"number": 42}],
        "comments": [review(HEAD)],
        "statusCheckRollup": [
            {"__typename": "CheckRun", "name": "test", "status": "COMPLETED", "conclusion": "SUCCESS",
             "detailsUrl": "https://example.invalid/run"}
        ],
    }
    base.update(over)
    return base


@pytest.fixture
def env(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    gh = bin_dir / "gh"
    gh.write_text(FAKE_GH)
    gh.chmod(gh.stat().st_mode | stat.S_IEXEC)
    (tmp_path / "ticket.json").write_text(json.dumps({"ticket": [], "parent": None, "parentLabels": []}))
    return {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "FAKE_LOG": str(tmp_path / "gh.log"),
        "FAKE_PR": str(tmp_path / "pr.json"),
        "FAKE_TICKET": str(tmp_path / "ticket.json"),
    }


def status(env, **over):
    Path(env["FAKE_PR"]).write_text(json.dumps(pr(**over)))
    out = subprocess.run([str(PR_STATUS), "7"], env=env, capture_output=True, text=True, check=True)
    return json.loads(out.stdout)


def test_a_reviewed_described_green_pr_merges(env):
    s = status(env)
    assert (s["next"], s["bodyMissing"], s["bodyDescribes"]) == ("merge", [], HEAD[:7])


@pytest.mark.parametrize(
    "drop, missing",
    [
        (("summary",), "## Summary"),
        (("evidence",), "## Evidence"),
        (("danger",), "## Merge Danger, **Door:**, **Blast Radius:**"),
    ],
)
def test_a_body_without_the_pr_template_goes_back_to_the_worker(env, drop, missing):
    s = status(env, body=body(drop=drop))
    assert s["next"] == "pr-body"
    assert missing in s["reason"]


def test_a_body_describing_an_older_commit_goes_back_to_the_worker(env):
    s = status(env, body=body(describes=OLD[:7]))
    assert s["next"] == "pr-body"
    assert s["reason"] == f"PR body describes {OLD[:7]}, head is {HEAD[:7]}"


def test_a_body_with_no_describes_line_goes_back_to_the_worker(env):
    s = status(env, body=body(describes=None))
    assert (s["next"], s["reason"]) == ("pr-body", "PR body has no Describes: <sha> line")


def test_a_full_describes_sha_counts(env):
    assert status(env, body=body(describes=HEAD))["next"] == "merge"


def test_the_body_check_comes_before_conflicts_and_ci(env):
    failing = [{"__typename": "CheckRun", "name": "test", "status": "COMPLETED", "conclusion": "FAILURE",
                "detailsUrl": "x"}]
    s = status(env, body=body(describes=OLD[:7]), mergeable="CONFLICTING", statusCheckRollup=failing)
    assert s["next"] == "pr-body"


def test_a_stale_review_is_reported_before_a_stale_body(env):
    s = status(env, body=body(describes=OLD[:7]), comments=[review(OLD)])
    assert s["next"] == "review"


def test_the_body_check_never_overrides_merged_or_the_round_limit(env):
    bad = body(drop=("summary",))
    assert status(env, body=bad, state="MERGED")["next"] == "merged"
    rounds = [review(OLD), review(OLD), review(HEAD)]
    assert status(env, body=bad, comments=rounds)["next"] == "round-limit"


def test_merge_ticket_refuses_a_pr_whose_body_is_stale(env):
    Path(env["FAKE_PR"]).write_text(json.dumps(pr(body=body(describes=OLD[:7]))))
    out = subprocess.run([str(MERGE_TICKET), "7"], env=env, capture_output=True, text=True)
    assert out.returncode == 1
    assert "next is 'pr-body'" in out.stderr
    assert "pr merge" not in Path(env["FAKE_LOG"]).read_text()
