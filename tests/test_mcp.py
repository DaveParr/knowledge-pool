"""Run the MCP smoke check against the fixture catalogue and a throwaway database."""

import os
import re
import subprocess
import sys
from pathlib import Path

import pytest

from tests.hosted_settings import HOSTED_SETTINGS
from tests.local_user import local_user_decks

ROOT = Path(__file__).resolve().parent.parent
LOG = ROOT / "test-artifacts" / "mcp_smoke.log"


def _text(out: bytes | str | None) -> str:
    if isinstance(out, bytes):
        return out.decode("utf-8", "replace")
    return out or ""


def _save_log(outcome: str, stdout: str, stderr: str) -> None:
    """Keep the smoke run's whole output. The assertion message only shows the
    tail, and the MCP server logs to stderr."""
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


def test_mcp_over_stdio_keeps_the_local_users_decks_across_processes(fixture_catalog, jac_db_url, tmp_path):
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
    # The decks went to the test's database, not this worktree's, as the local user's.
    assert "MCP Burn" in {d.name for d in local_user_decks(tmp_path)}


def _start_mcp(catalog, db_url: str, **settings: str) -> subprocess.CompletedProcess:
    """Start the MCP server with `settings` added to its environment, and wait
    for it to exit (a server that starts is stopped after 60 seconds)."""
    env = {**os.environ, "KP_CATALOG": str(catalog), "JAC_DB_URL": db_url, **settings}
    return subprocess.run(
        [sys.executable, "run", "--no-serve", "mcp_server.jac"],
        cwd=ROOT, env=env, capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL,
    )


def test_local_mode_refuses_to_listen_beyond_loopback(fixture_catalog, jac_db_url):
    run = _start_mcp(fixture_catalog, jac_db_url, KP_MODE="local", KP_TRANSPORT="http", KP_HTTP_HOST="0.0.0.0", KP_HTTP_PORT="0")
    assert run.returncode != 0
    assert "Local mode listens on 127.0.0.1 only, not 0.0.0.0." in run.stderr


def test_hosted_mode_refuses_to_start_without_any_of_its_settings(fixture_catalog, jac_db_url):
    run = _start_mcp(fixture_catalog, jac_db_url, KP_MODE="hosted", **{name: "" for name in [*HOSTED_SETTINGS, "JAC_DB_URL"]})
    assert run.returncode != 0
    for name in [*HOSTED_SETTINGS, "JAC_DB_URL"]:
        assert name in run.stderr


@pytest.mark.parametrize("missing", [*sorted(HOSTED_SETTINGS), "JAC_DB_URL"])
def test_hosted_mode_refuses_to_start_when_one_setting_is_missing(fixture_catalog, jac_db_url, missing):
    settings = {**HOSTED_SETTINGS, "KP_TRANSPORT": "http", "KP_HTTP_PORT": "0", missing: ""}
    run = _start_mcp(fixture_catalog, jac_db_url, KP_MODE="hosted", **settings)
    assert run.returncode != 0
    assert missing in run.stderr
    assert all(other not in run.stderr for other in [*HOSTED_SETTINGS, "JAC_DB_URL"] if other != missing)
