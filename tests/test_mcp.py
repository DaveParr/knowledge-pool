"""Run the MCP smoke check against the fixture catalogue and a throwaway graph."""

import os
import socket
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOG = ROOT / "test-artifacts" / "mcp_smoke.log"


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _text(out: bytes | str | None) -> str:
    if isinstance(out, bytes):
        return out.decode("utf-8", "replace")
    return out or ""


def _save_log(outcome: str, stdout: str, stderr: str) -> None:
    """Keep the smoke run's whole output. The assertion message only shows the
    tail, and the MCP server (and the web app it runs) logs to stderr."""
    LOG.parent.mkdir(exist_ok=True)
    LOG.write_text(f"{outcome}\n\n== stdout ==\n{stdout}\n== stderr ==\n{stderr}")


def test_mcp_over_stdio_shares_decks_with_the_web_app(fixture_catalog, tmp_path):
    env = {**os.environ, "KP_CATALOG": str(fixture_catalog), "JAC_DATA_PATH": str(tmp_path)}
    try:
        run = subprocess.run(
            [sys.executable, str(ROOT / "scripts" / "mcp_smoke.py"), str(_free_port())],
            cwd=ROOT, env=env, capture_output=True, text=True, timeout=300,
        )
    except subprocess.TimeoutExpired as hung:
        _save_log("timed out after 300s", _text(hung.stdout), _text(hung.stderr))
        raise
    if run.returncode != 0 or "all checks passed" not in run.stdout:
        _save_log(f"exit code {run.returncode}", run.stdout, run.stderr)
    assert run.returncode == 0, run.stdout[-3000:] + run.stderr[-3000:] + f"\n\nFull output: {LOG}"
    assert "all checks passed" in run.stdout, f"Full output: {LOG}"
    assert (tmp_path / ".jac" / "data").exists()  # the graph went to the throwaway path
