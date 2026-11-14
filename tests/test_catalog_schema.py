"""Startup check: a catalogue built by older code is reported as out of date."""

import os
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

from catalog import store
from tests.old_catalog import drop_card_details, drop_commander_fields, drop_produced_mana

ROOT = Path(__file__).resolve().parent.parent


def _make_old_schema(path):
    """Turn a current catalogue into one built before produced_mana (#48) and oracle tags (#46)."""
    con = sqlite3.connect(path)
    drop_produced_mana(con)
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
    assert "jac x catalogue" in message


def test_catalogue_from_before_card_details_names_the_new_columns(fixture_catalog):
    con = sqlite3.connect(fixture_catalog)
    drop_card_details(con)
    con.commit()
    con.close()
    store.reset()
    with pytest.raises(store.CatalogOutOfDate) as caught:
        store.check_current()
    message = str(caught.value)
    for column in ("power", "toughness", "loyalty", "defense", "keywords", "faces"):
        assert f"cards.{column}" in message
    assert "cards.produced_mana" not in message
    assert "jac x catalogue" in message


def _run_entry_point(args, catalog):
    """Run `jac <args>` against `catalog`. A server that starts anyway is killed after 60s."""
    env = {**os.environ, "KP_CATALOG": str(catalog)}
    return subprocess.run(
        [sys.executable, *args],
        cwd=ROOT, env=env, capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL,
    )


@pytest.mark.usefixtures("jac_db_url")
def test_mcp_server_refuses_to_start_on_an_old_catalogue_and_keeps_stdout_clean(old_catalog):
    run = _run_entry_point(["run", "--no-serve", "mcp_server.jac"], old_catalog)
    assert run.returncode != 0
    assert "jac x catalogue" in run.stderr
    assert run.stdout == ""  # stdout is the MCP protocol channel


@pytest.mark.usefixtures("jac_db_url")
def test_web_server_refuses_to_start_on_an_old_catalogue(old_catalog):
    run = _run_entry_point(["run", "--host", "127.0.0.1", "--port", str(_free_port()), "--no-client", "main.jac"], old_catalog)
    assert run.returncode != 0
    assert "jac x catalogue" in run.stdout + run.stderr


def _free_port() -> int:
    import socket

    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def test_catalogue_from_before_commander_fields_names_the_new_columns(fixture_catalog):
    con = sqlite3.connect(fixture_catalog)
    drop_commander_fields(con)
    con.commit()
    con.close()
    store.reset()
    with pytest.raises(store.CatalogOutOfDate) as caught:
        store.check_current()
    assert "cards.leadership_skills" in str(caught.value)
    assert "cards.game_changer" in str(caught.value)
    assert "cards.faces" not in str(caught.value)
