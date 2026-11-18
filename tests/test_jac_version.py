"""One Jac version: the exact pin in jac.toml is the one that runs the tests (and so CI)."""

import re
import subprocess
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def test_the_jac_running_the_tests_is_the_pinned_version():
    pin = tomllib.loads((ROOT / "jac.toml").read_text())["project"]["jac-version"]
    assert re.fullmatch(r"==\d+\.\d+\.\d+", pin), f"jac-version must be one exact version, not {pin!r}"
    running = subprocess.run([sys.executable, "--version"], capture_output=True, text=True, timeout=60).stdout
    assert running.split()[:2] == ["jac", pin.removeprefix("==")], running
