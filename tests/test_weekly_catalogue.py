"""The weekly catalogue rebuild workflow (#137): the rules that keep it honest
without running it (the run against Railway is checked by hand, see the PR)."""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORKFLOW = (ROOT / ".github" / "workflows" / "weekly-catalogue.yml").read_text()
RUNS = re.findall(r"^\s*(?:- )?run: (.+)$", WORKFLOW, re.MULTILINE) + re.findall(
    r"run: \|\n((?:\s{10,}.+\n)+)", WORKFLOW
)


def test_it_runs_on_monday_mornings_and_by_hand():
    cron = re.search(r'cron: "([^"]+)"', WORKFLOW).group(1)
    minute, hour, _, _, weekday = cron.split()
    assert weekday == "1" and int(hour) < 12
    assert "workflow_dispatch:" in WORKFLOW


def test_it_builds_main():
    assert re.search(r"uses: actions/checkout@\S+\n\s+with:\n\s+ref: main\n", WORKFLOW)


def test_it_writes_the_file_the_catalogue_step_depends_on():
    # The file the Dockerfile copies just before `jac x catalogue` (test_dockerfile.py).
    assert any("> catalogue_date.txt" in run for run in RUNS)


def test_it_deploys_with_the_project_token_and_waits_for_the_build():
    assert "RAILWAY_TOKEN: ${{ secrets.RAILWAY_TOKEN }}" in WORKFLOW
    up = next(run for run in RUNS if "railway up" in run)
    # Not detached: the build's result is the workflow's.
    assert "--ci" in up and "--detach" not in up and "-d " not in up
    assert "--service knowledge-pool" in up


def test_it_commits_nothing():
    assert "contents: read" in WORKFLOW
    assert not re.search(r"\bgit (commit|push)\b", WORKFLOW)
