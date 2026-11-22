"""A ticket PR as `gh pr view --json` returns it, for the ticket-script tests."""

HEAD = "def5678" + "0" * 33
OLD = "abc1234" + "0" * 33


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
