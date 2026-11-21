"""The catalogue rebuild workflow (#137), run by hand for now: the rules that keep it honest
without running it (the run against Railway is checked by hand, see the PR)."""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = (ROOT / ".github" / "workflows" / "weekly-catalogue.yml").read_text()


def _railway_up() -> list[str]:
    """The arguments of the workflow's one `railway up` command."""
    (line,) = re.findall(r"^\s*run: railway up(.*)$", WORKFLOW, re.MULTILINE)
    return line.split()


def test_the_workflow_runs_only_by_hand_for_now():
    assert re.search(r"^  workflow_dispatch:", WORKFLOW, re.MULTILINE)
    # The weekly schedule is off: no uncommented `schedule:` trigger.
    assert not re.search(r"^\s*schedule:", WORKFLOW, re.MULTILINE)


def test_the_workflow_keeps_the_monday_morning_schedule_to_turn_back_on():
    cron = re.search(r'^\s*#\s+- cron: "([^"]+)"', WORKFLOW, re.MULTILINE).group(1)
    minute, hour, _, _, weekday = cron.split()
    assert weekday == "1" and int(hour) < 12


def test_the_workflow_builds_the_newest_commit_on_main_whose_tests_passed():
    assert "--workflow test.yml --branch main" in WORKFLOW and "--status success" in WORKFLOW
    assert "ref: ${{ steps.tested.outputs.sha }}" in WORKFLOW


def test_the_workflow_writes_the_file_the_catalogue_step_depends_on():
    # The file the Dockerfile copies just before `jac x catalogue` (test_dockerfile.py).
    assert re.search(r"^\s*date .*> catalogue_date\.txt$", WORKFLOW, re.MULTILINE)


def test_the_workflow_deploys_with_the_project_token_and_waits_for_the_build():
    assert "RAILWAY_TOKEN: ${{ secrets.RAILWAY_TOKEN }}" in WORKFLOW
    args = _railway_up()
    # Not detached: the build's result is the workflow's.
    assert "--ci" in args and not {"-d", "--detach", "--no-wait"} & set(args)


def test_the_workflow_deploys_to_the_app_service():
    args = _railway_up()
    assert args[args.index("--service") + 1] == "knowledge-pool"


def test_the_workflow_commits_nothing():
    assert "contents: read" in WORKFLOW
    assert not re.search(r"\bgit (commit|push)\b", WORKFLOW)
