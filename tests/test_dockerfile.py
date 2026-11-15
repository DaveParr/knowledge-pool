"""The container image's Dockerfile: the rules that keep it honest without a
Docker build (the run against a real Postgres is checked by hand, see the PR)."""

import re
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DOCKERFILE = (ROOT / "Dockerfile").read_text()


def _instructions() -> list[tuple[str, str]]:
    """(instruction, arguments) for each Dockerfile instruction, continuation lines joined."""
    text = re.sub(r"\\\n", " ", DOCKERFILE)
    lines = [line.strip() for line in text.splitlines() if line.strip() and not line.strip().startswith("#")]
    return [tuple(line.split(None, 1)) for line in lines]


def test_the_base_image_is_the_jac_version_the_project_pins():
    pin = tomllib.loads((ROOT / "jac.toml").read_text())["project"]["jac-version"]
    assert pin.startswith("==")
    args = dict(a.split("=", 1) for i, a in _instructions() if i == "ARG" and "=" in a)
    assert args["JAC_VERSION"] == pin[2:]
    assert ("FROM", "jaseci/jaclang:${JAC_VERSION}") in _instructions()


def test_every_jac_build_step_names_a_database_so_none_is_started():
    steps = [a for i, a in _instructions() if i == "RUN" and re.search(r"\bjac\b", a)]
    assert len(steps) >= 3  # install, web bundle, catalogue
    assert all("JAC_DB_URL=" in step for step in steps), steps


def test_the_catalogue_step_comes_after_the_date_file_is_copied():
    instructions = _instructions()
    copy = next(n for n, (i, a) in enumerate(instructions) if i == "COPY" and "catalogue_date.txt" in a)
    catalogue = next(n for n, (i, a) in enumerate(instructions) if i == "RUN" and "jac x catalogue" in a)
    assert copy < catalogue
    # The app's own source comes after it, so editing the app does not rebuild the catalogue.
    assert ("COPY", "--chown=jac:jac . .") in instructions[catalogue:]
    assert (ROOT / "catalogue_date.txt").read_text().strip()


def test_the_image_sets_hosted_mode_and_builds_the_web_bundle_and_installs_the_app():
    runs = " ".join(a for i, a in _instructions() if i == "RUN")
    assert "jac install" in runs and "jac build --as client" in runs
    env = " ".join(a for i, a in _instructions() if i == "ENV")
    assert "KP_MODE=hosted" in env and "KP_TRANSPORT=http" in env


def test_the_image_is_not_given_the_tests_or_local_state():
    ignored = (ROOT / ".dockerignore").read_text().split()
    assert {".git", ".jac", "node_modules", "data"} <= set(ignored)
