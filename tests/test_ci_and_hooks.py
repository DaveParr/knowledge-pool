"""The CI workflow's triggers and the PostToolUse hook that checks a ticket PR's link."""

import json
import os
import re
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = (ROOT / ".github" / "workflows" / "test.yml").read_text()
HOOK = ROOT / ".claude" / "hooks" / "check-ticket-link-on-pr.sh"


def trigger_block(name):
    """The lines under `on: <name>:`, up to the next trigger."""
    m = re.search(rf"^  {name}:\n((?:    .*\n|\n)*)", WORKFLOW, re.M)
    assert m, f"no {name} trigger in test.yml"
    return m.group(1)


def test_ci_runs_for_pull_requests_whatever_their_base():
    assert "branches" not in trigger_block("pull_request")


def test_ci_runs_in_the_merge_queue():
    assert re.search(r"^  merge_group:", WORKFLOW, re.M)


@pytest.fixture
def ticket_repo(tmp_path):
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    (tmp_path / ".ticket").write_text("42\n")
    script = tmp_path / "scripts" / "check-ticket-link.sh"
    script.parent.mkdir()
    script.write_text("#!/usr/bin/env bash\necho unlinked >&2\nexit 1\n")
    script.chmod(0o755)
    return tmp_path


def run_hook(repo, command):
    event = json.dumps({"tool_input": {"command": command}, "cwd": str(repo)})
    return subprocess.run([str(HOOK)], input=event, capture_output=True, text=True, env=os.environ)


@pytest.mark.parametrize(
    "command",
    ["gh pr create --base main", "gh stack submit --auto", "gh stack add DaveParr/43-next", "cd x && gh stack submit"],
)
def test_the_hook_checks_the_link_after_a_pr_is_opened(ticket_repo, command):
    out = run_hook(ticket_repo, command)
    assert out.returncode == 2
    assert "Ticket link check failed for #42" in out.stderr


@pytest.mark.parametrize("command", ["gh pr view 3", "gh stack view --json", "git push"])
def test_the_hook_ignores_other_commands(ticket_repo, command):
    assert run_hook(ticket_repo, command).returncode == 0


SETTINGS = json.loads((ROOT / ".claude" / "settings.json").read_text())

NEVER_DELETE = [
    "Bash(gh api * --method DELETE*)",
    "Bash(gh api * -X DELETE*)",
    "Bash(gh api --method DELETE *)",
    "Bash(gh api --method=DELETE *)",
    "Bash(gh api -X DELETE *)",
    "Bash(gh api -XDELETE *)",
    "Bash(gh pr merge * --delete-branch*)",
    "Bash(gh pr merge * -d*)",
    "Bash(gh pr merge --delete-branch*)",
    "Bash(gh repo delete*)",
    "Bash(git branch --delete *)",
    "Bash(git branch -D *)",
    "Bash(git branch -d *)",
    "Bash(git push * --delete *)",
    "Bash(git push * -d *)",
    "Bash(git push * :*)",
    "Bash(git push --delete *)",
]


@pytest.mark.parametrize("rule", NEVER_DELETE)
def test_workers_may_not_delete_branches_or_repos(rule):
    assert rule in SETTINGS["permissions"]["deny"]


def test_no_allow_rule_names_a_removed_script():
    for gone in ("ready-tickets.sh", "park-ticket.sh"):
        assert not any(gone in rule for rule in SETTINGS["permissions"]["allow"])
