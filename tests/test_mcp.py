"""Run the MCP smoke check against the fixture catalogue and a throwaway database."""

import os
import re
import subprocess
import sys
from pathlib import Path

from tests.local_decks import local_user_decks

ROOT = Path(__file__).resolve().parent.parent
LOG = ROOT / "test-artifacts" / "mcp_smoke.log"


def _text(out: bytes | str | None) -> str:
    if isinstance(out, bytes):
        return out.decode("utf-8", "replace")
    return out or ""


def _save_log(outcome: str, stdout: str, stderr: str) -> None:
    """Keep the smoke run's whole output. The assertion message only shows the
    tail, and the MCP server and the web app log to stderr."""
    LOG.parent.mkdir(exist_ok=True)
    LOG.write_text(f"{outcome}\n\n== stdout ==\n{stdout}\n== stderr ==\n{stderr}")


# JSON-RPC methods a view may send to its host (MCP Apps spec 2026-01-26, plus
# ui/download-file from the draft, used only when the host offers it).
VIEW_METHODS = {
    "ui/initialize", "ui/notifications/initialized", "ui/notifications/size-changed",
    "tools/call", "ui/download-file",
}


def test_export_view_only_sends_mcp_apps_methods():
    page = (ROOT / "ui" / "deck_export.html").read_text()
    sent = set(re.findall(r'(?:request|notify)\("([^"]+)"', page))
    assert sent == VIEW_METHODS, sent
    assert "hostCaps.downloadFile" in page  # ui/download-file only when the host advertises it


def test_mcp_over_stdio_builds_the_local_users_decks_in_one_database(fixture_catalog, jac_db_url, tmp_path):
    env = {**os.environ, "KP_CATALOG": str(fixture_catalog), "JAC_DB_URL": jac_db_url}
    try:
        run = subprocess.run(
            [sys.executable, "run", "--no-serve", str(ROOT / "scripts" / "mcp_smoke.py")],
            cwd=ROOT, env=env, capture_output=True, text=True, timeout=300,
        )
    except subprocess.TimeoutExpired as hung:
        _save_log("timed out after 300s", _text(hung.stdout), _text(hung.stderr))
        raise
    if run.returncode != 0 or "all checks passed" not in run.stdout:
        _save_log(f"exit code {run.returncode}", run.stdout, run.stderr)
    assert run.returncode == 0, run.stdout[-3000:] + run.stderr[-3000:] + f"\n\nFull output: {LOG}"
    assert "all checks passed" in run.stdout, f"Full output: {LOG}"
    # The decks are the local user's, in the test's database, not this worktree's.
    assert {"MCP Burn", "MCP Krenko", "MCP Krenko Study"} == set(local_user_decks(jac_db_url, tmp_path))
