"""API tests: decks over REST, decks survive a server restart, and strict permissions are on."""

import os
import subprocess
import sys
from pathlib import Path

import pytest
from tests.front_door_client import FrontDoorClient

ROOT = Path(__file__).resolve().parent.parent
pytestmark = pytest.mark.usefixtures("jac_db_url")


def _deck_names(client: JacTestClient) -> list[str]:
    resp = client.post("/walker/ListDecks")
    assert resp.is_success, resp.json()
    return [d["name"] for d in resp.json()["data"]["reports"][0]]


def test_create_and_list_decks(tmp_path):
    client = FrontDoorClient(tmp_path)
    try:
        resp = client.post("/walker/CreateDeck", json={"name": "Izzet Tempo"})
        assert resp.is_success, resp.json()
        assert _deck_names(client) == ["Izzet Tempo"]
    finally:
        client.close()


def _error(report: dict) -> dict:
    return {k: report[k] for k in ("code", "message")}


def test_blank_name_creates_nothing_and_says_why(tmp_path):
    client = FrontDoorClient(tmp_path)
    try:
        resp = client.post("/walker/CreateDeck", json={"name": "   "})
        assert [_error(r) for r in resp.json()["data"]["reports"]] == [
            {"code": "blank-name", "message": "A deck needs a name."}
        ]
        resp = client.post("/walker/CreateDeck", json={"name": "Vintage deck", "format": "vintage"})
        [err] = resp.json()["data"]["reports"]
        assert err["code"] == "unknown-format" and err["message"].startswith("Unknown format vintage. Use one of: standard")
        assert _deck_names(client) == []
    finally:
        client.close()


def test_decks_survive_restart(tmp_path):
    first = FrontDoorClient(tmp_path)
    first.post("/walker/CreateDeck", json={"name": "Golgari Food"})
    first.close()

    second = FrontDoorClient(tmp_path)
    try:
        assert _deck_names(second) == ["Golgari Food"]
    finally:
        second.close()



# Imports one of the app's modules in a fresh process and says whether strict
# permissions are on. Run standalone, outside the project, so nothing is built.
STRICT_PROBE = """
import sys
from jaclang import JacRuntime as Jac
Jac.jac_import(target=sys.argv[2], base_path=sys.argv[1], lng="jac")
print("strict" if Jac.strict_permissions else "lax")
"""


@pytest.mark.parametrize("module", ["main", "graph_runner"])  # mcp_server and seed import graph_runner
def test_app_processes_run_with_strict_permissions(module, tmp_path):
    """A write Jac refuses must fail the call, even with JAC_STRICT_PERMISSIONS unset."""
    probe = tmp_path / "probe.py"
    probe.write_text(STRICT_PROBE)
    env = {k: v for k, v in os.environ.items() if k != "JAC_STRICT_PERMISSIONS"}
    run = subprocess.run(
        [sys.executable, "run", "--no-serve", "--no-takeover", str(probe), str(ROOT), module],
        cwd=tmp_path, env=env, capture_output=True, text=True, timeout=300,
    )
    assert run.stdout.strip().splitlines()[-1:] == ["strict"], run.stdout + run.stderr
