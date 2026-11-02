"""Run the MCP smoke check against the fixture catalogue and a throwaway graph."""

import os
import socket
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def test_mcp_over_stdio_shares_decks_with_the_web_app(fixture_catalog, tmp_path):
    env = {**os.environ, "KP_CATALOG": str(fixture_catalog), "JAC_DATA_PATH": str(tmp_path)}
    run = subprocess.run(
        [sys.executable, str(ROOT / "scripts" / "mcp_smoke.py"), str(_free_port())],
        cwd=ROOT, env=env, capture_output=True, text=True, timeout=300,
    )
    assert run.returncode == 0, run.stdout[-3000:] + run.stderr[-3000:]
    assert "all checks passed" in run.stdout
    assert (tmp_path / ".jac" / "data").exists()  # the graph went to the throwaway path
