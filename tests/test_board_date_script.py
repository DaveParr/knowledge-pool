"""The board's Start date and Target date: scripts/board-date.sh (the `board_date` helper),
scripts/target-date.sh, and the dates start-ticket.sh and merge-ticket.sh write.

`gh` is a fake on PATH that answers from a board the test describes (its date fields, the
ticket's card and dates, how the ticket closed, the PR), runs the script's `--jq` filter
over that answer with the real `jq`, and logs every call, so these tests run offline."""

import json
import os
import stat
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
BOARD_DATE = ROOT / "scripts" / "board-date.sh"
TARGET_DATE = ROOT / "scripts" / "target-date.sh"
START_TICKET = ROOT / "scripts" / "start-ticket.sh"
MERGE_TICKET = ROOT / "scripts" / "merge-ticket.sh"

FAKE_GH = r'''#!/usr/bin/env python3
import json, os, subprocess, sys

args = sys.argv[1:]
with open(os.environ["FAKE_LOG"], "a") as log:
    log.write(json.dumps(args) + "\n")
board = json.load(open(os.environ["FAKE_BOARD"]))


def opt(name):
    return args[args.index(name) + 1] if name in args else None


def var(name):
    for i, a in enumerate(args):
        if a in ("-F", "-f") and args[i + 1].startswith(name + "="):
            return args[i + 1].split("=", 1)[1]


def reply(data):
    jq = opt("--jq")
    if jq is None:
        print(json.dumps(data))
    else:
        out = subprocess.run(["jq", "-r", jq], input=json.dumps(data), text=True, capture_output=True)
        sys.stdout.write(out.stdout)
        sys.stderr.write(out.stderr)
        sys.exit(out.returncode)


cmd = " ".join(args[:2])
if args[0] == "--version":
    print("gh version 2.105.0 (2026-11-17)")
elif cmd == "api graphql":
    query = var("query")
    if "fields(first" in query:
        nodes = [{"name": f, "dataType": "DATE"} for f in board["dateFields"]] + [{}]
        reply({"data": {"user": {"projectV2": {"fields": {"nodes": nodes}}}}})
    elif "projectItems" in query:
        other = {"project": {"number": 3, "owner": {"login": "DaveParr"}}, "fieldValueByName": None}
        nodes = [other]
        if board["card"]:
            date = board["dates"].get(var("field"))
            nodes.append({"project": {"number": 7, "owner": {"login": "DaveParr"}},
                          "fieldValueByName": {"date": date} if date else None})
        reply({"data": {"repository": {"issue": {"projectItems": {"nodes": nodes}}}}})
    elif "timelineItems" in query:
        issue = board["issue"]
        closer = {"mergedAt": issue["mergedAt"]} if issue.get("mergedAt") else {}
        nodes = [{"closer": closer}] if issue["state"] == "CLOSED" else []
        reply({"data": {"repository": {"issue": {"state": issue["state"], "closedAt": issue.get("closedAt"),
                                                 "timelineItems": {"nodes": nodes}}}}})
    elif "labels(first" in query:
        reply({"data": {"repository": {"issue": {"labels": {"nodes": []}, "parent": None}}}})
    else:
        sys.exit("fake gh: unexpected query")
elif cmd == "project field-list":
    reply({"fields": [{"name": "Status", "options": [{"name": s} for s in ("In progress", "Blocked")]}]})
elif cmd == "issue view":
    reply({"title": "A ticket", "state": board["issue"]["state"]})
elif cmd == "pr view":
    reply(board["pr"])
elif cmd in ("project item-add", "project item-edit", "issue edit", "issue close", "issue comment", "pr merge", "pr edit",
             "pr comment"):
    pass
else:
    sys.exit("fake gh: unexpected: " + " ".join(args))
'''

HEAD = "def5678" + "0" * 33
PR = {
    "number": 7, "url": "https://github.com/DaveParr/knowledge-pool/pull/7", "state": "OPEN", "isDraft": False,
    "baseRefName": "main", "headRefOid": HEAD, "mergeable": "MERGEABLE", "labels": [],
    "body": f"Ticket: #42\n\n## Summary\n\nx\n\n## Evidence\n\nDescribes: `{HEAD[:7]}`\n\n"
            "## Merge Danger\n\n**Door:** two-way\n\n**Blast Radius:** none",
    "closingIssuesReferences": [{"number": 42}],
    "comments": [{"body": f"## Code review, round 1\n\nReviewed `{HEAD[:7]}`."}],
    "statusCheckRollup": [{"__typename": "CheckRun", "name": "test", "status": "COMPLETED",
                           "conclusion": "SUCCESS", "detailsUrl": "x"}],
    "mergedAt": "2026-11-21T23:59:59Z",
}


def make_bin(tmp_path, name, text):
    path = tmp_path / "bin" / name
    path.parent.mkdir(exist_ok=True)
    path.write_text(text)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


@pytest.fixture
def env(tmp_path):
    make_bin(tmp_path, "gh", FAKE_GH)
    return {
        **os.environ,
        "PATH": f"{tmp_path / 'bin'}:{os.environ['PATH']}",
        "FAKE_LOG": str(tmp_path / "gh.log"),
        "FAKE_BOARD": str(tmp_path / "board.json"),
    }


def board(env, card=True, dates=None, fields=("Start date", "Target date"), issue=None, pr=None):
    Path(env["FAKE_BOARD"]).write_text(json.dumps({
        "card": card, "dates": dates or {}, "dateFields": list(fields),
        "issue": issue or {"state": "OPEN"}, "pr": pr or PR,
    }))


def run(env, script, *args):
    return subprocess.run([str(script), *args], env=env, capture_output=True, text=True)


def calls(env):
    log = Path(env["FAKE_LOG"])
    return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []


def date_writes(env):
    """(field, date) for every date the script wrote to the board."""
    return [(c[c.index("--field") + 1], c[c.index("--date") + 1])
            for c in calls(env) if c[:2] == ["project", "item-edit"] and "--date" in c]


def test_board_date_sets_the_field_on_the_tickets_card(env):
    board(env)
    out = run(env, BOARD_DATE, "42", "Start date", "2026-11-22")
    assert out.returncode == 0, out.stderr
    assert date_writes(env) == [("Start date", "2026-11-22")]
    edit = next(c for c in calls(env) if c[:2] == ["project", "item-edit"])
    assert edit[edit.index("--url") + 1] == "https://github.com/DaveParr/knowledge-pool/issues/42"


def test_board_date_with_no_date_prints_the_current_one(env):
    board(env, dates={"Target date": "2026-11-20"})
    assert run(env, BOARD_DATE, "42", "Target date").stdout == "2026-11-20\n"
    assert run(env, BOARD_DATE, "42", "Start date").stdout == "\n"


@pytest.mark.parametrize(
    "args",
    [(), ("42",), ("x", "Start date"), ("42", "Start date", "2026-11-22", "extra")],
)
def test_board_date_rejects_bad_arguments_with_usage(env, args):
    board(env)
    out = run(env, BOARD_DATE, *args)
    assert out.returncode == 2
    assert out.stderr.startswith("usage: scripts/board-date.sh")
    assert not [c for c in calls(env) if c[0] != "--version"]


@pytest.mark.parametrize("date", ["22-11-2026", "2026-11-2", "2026-13-01", "2026-11-32", "today"])
def test_board_date_refuses_a_malformed_date_before_calling_github(env, date):
    board(env)
    out = run(env, BOARD_DATE, "42", "Start date", date)
    assert out.returncode == 1
    assert f'Not a date: "{date}"' in out.stderr
    assert not [c for c in calls(env) if c[0] != "--version"]


def test_board_date_fails_closed_on_a_field_the_board_lacks(env):
    board(env, fields=("Target date",))
    out = run(env, BOARD_DATE, "42", "Start date", "2026-11-22")
    assert out.returncode == 1
    assert 'no date field "Start date". Date fields: Target date.' in out.stderr
    assert date_writes(env) == []


def test_board_date_fails_closed_when_the_ticket_has_no_card(env):
    board(env, card=False)
    out = run(env, BOARD_DATE, "42", "Start date", "2026-11-22")
    assert out.returncode == 1
    assert "#42 has no card on the board" in out.stderr
    assert date_writes(env) == []
    assert not [c for c in calls(env) if c[:2] == ["project", "item-add"]]


def test_target_date_is_the_merge_date_when_a_pr_closed_the_ticket(env):
    board(env, issue={"state": "CLOSED", "closedAt": "2026-11-22T00:00:05Z", "mergedAt": "2026-11-21T23:59:59Z"})
    out = run(env, TARGET_DATE, "42")
    assert out.returncode == 0, out.stderr
    assert date_writes(env) == [("Target date", "2026-11-21")]


def test_target_date_is_the_close_date_when_no_pr_closed_the_ticket(env):
    board(env, issue={"state": "CLOSED", "closedAt": "2026-11-19T10:00:00Z"})
    assert run(env, TARGET_DATE, "42").returncode == 0
    assert date_writes(env) == [("Target date", "2026-11-19")]


def test_target_date_refuses_an_open_ticket(env):
    board(env)
    out = run(env, TARGET_DATE, "42")
    assert out.returncode == 1
    assert "#42 is still open" in out.stderr
    assert date_writes(env) == []


def test_merge_ticket_sets_the_target_date_to_the_merge_date(env):
    board(env, issue={"state": "CLOSED"})
    out = run(env, MERGE_TICKET, "7")
    assert out.returncode == 0, out.stderr
    assert date_writes(env) == [("Target date", "2026-11-21")]


@pytest.fixture
def start_env(env, tmp_path):
    """start-ticket.sh with the plugin installed, stopped by `git fetch` right after the claim."""
    make_bin(tmp_path, "claude", "#!/usr/bin/env bash\necho '[{\"id\": \"mattpocock-skills@mattpocock\"}]'\n")
    make_bin(tmp_path, "git", f'#!/usr/bin/env bash\n[ "$1" = rev-parse ] && echo "{ROOT}" && exit 0\nexit 1\n')
    return env


def test_start_ticket_sets_todays_start_date_on_a_new_ticket(start_env):
    board(start_env)
    today = subprocess.run(["date", "-u", "+%F"], capture_output=True, text=True).stdout.strip()
    run(start_env, START_TICKET, "42")
    assert date_writes(start_env) == [("Start date", today)]


def test_start_ticket_keeps_the_start_date_of_a_restarted_ticket(start_env):
    board(start_env, dates={"Start date": "2026-11-01"})
    run(start_env, START_TICKET, "42")
    assert [c for c in calls(start_env) if c[:2] == ["project", "item-edit"]]  # it did claim
    assert date_writes(start_env) == []


def test_park_ticket_leaves_the_dates_alone(env, tmp_path):
    board(env, dates={"Start date": "2026-11-01"})
    comment = tmp_path / "why.md"
    comment.write_text("Needs a decision.")
    out = run(env, ROOT / "scripts" / "park-ticket.sh", "42", str(comment))
    assert out.returncode == 0, out.stderr
    assert date_writes(env) == []
