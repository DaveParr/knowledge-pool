"""Startup check: a catalogue built by older code is reported as out of date."""

import os
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

from catalog import store

ROOT = Path(__file__).resolve().parent.parent


def _make_old_schema(path):
    """Turn a current catalogue into one built before produced_mana (#48) and oracle tags (#46)."""
    con = sqlite3.connect(path)
    con.execute("ALTER TABLE cards DROP COLUMN produced_mana")
    con.execute("DROP TABLE card_tags")
    con.commit()
    con.close()
    store.reset()


@pytest.fixture
def old_catalog(fixture_catalog):
    _make_old_schema(fixture_catalog)
    return fixture_catalog


def test_current_catalogue_passes_the_check():
    store.check_current()


def test_old_schema_catalogue_names_what_is_missing_and_the_ingest_command(old_catalog):
    with pytest.raises(store.CatalogOutOfDate) as caught:
        store.check_current()
    message = str(caught.value)
    assert str(old_catalog) in message
    assert "cards.produced_mana" in message
    assert "card_tags" in message
    assert "uv run python -m catalog.ingest" in message


def _run_entry_point(args, catalog, tmp_path):
    """Run `jac <args>` against `catalog`. A server that starts anyway is killed after 60s."""
    env = {**os.environ, "KP_CATALOG": str(catalog), "JAC_DATA_PATH": str(tmp_path), "KP_WEB": "0"}
    jac = Path(sys.executable).parent / "jac"
    return subprocess.run(
        [str(jac), *args],
        cwd=ROOT, env=env, capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL,
    )


def test_mcp_server_refuses_to_start_on_an_old_catalogue_and_keeps_stdout_clean(old_catalog, tmp_path):
    run = _run_entry_point(["run", "mcp_server.jac"], old_catalog, tmp_path)
    assert run.returncode != 0
    assert "uv run python -m catalog.ingest" in run.stderr
    assert run.stdout == ""  # stdout is the MCP protocol channel


def test_web_server_refuses_to_start_on_an_old_catalogue(old_catalog, tmp_path):
    run = _run_entry_point(["start", "main.jac", "--port", str(_free_port()), "--no_client"], old_catalog, tmp_path)
    assert run.returncode != 0
    assert "uv run python -m catalog.ingest" in run.stdout + run.stderr


def _free_port() -> int:
    import socket

    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]
