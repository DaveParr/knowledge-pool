"""The MCP tools called in process (`mcp_server.jac`) through the server, as the
connector calls them, on the local user. Every failure reaches the caller the
same way: a tool error (`is_error`) whose structured content is `{error, code}`."""

import sys

import anyio
import pytest
from jaclang.testing.testing import JacTestClient
from jaclang.runtime.exceptions import WriteConflict
from uuid import uuid4

pytestmark = pytest.mark.usefixtures("jac_db_url")

MISSING = "no-such-deck-id"


@pytest.fixture
def app(tmp_path):
    # Imported first, so the app's modules and the tools' are the same ones.
    import mcp_server

    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    # The first request sets Jac up on the test's database in this process.
    assert client.get("/healthz").status_code == 200
    try:
        yield mcp_server
    finally:
        client.close()


def call(app, tool, **arguments):
    return anyio.run(app.server.call_tool, tool, arguments)


def failure(result):
    assert result.is_error, result
    assert set(result.structured_content) == {"error", "code"}, result.structured_content
    assert result.content[0].text == result.structured_content["error"]
    return result.structured_content["code"]


def data(result):
    assert not result.is_error, result
    sc = result.structured_content
    return sc["result"] if set(sc) == {"result"} else sc


@pytest.fixture
def deck_id(app):
    return data(call(app, "deck_create", name="Burn", format="modern"))["id"]


# Every tool that takes a deck id, with the arguments besides it.
DECK_TOOLS = {
    "deck_get": {},
    "deck_show": {},
    "deck_analyze": {},
    "deck_validate": {},
    "deck_copy": {},
    "deck_edit": {"changes": []},
    "deck_import": {"format": "text", "text": "1 Shock"},
    "deck_export": {},
    "card_search": {"query": "bolt"},
}


@pytest.mark.parametrize("tool", sorted(DECK_TOOLS))
def test_deck_tool_on_an_unknown_deck_is_a_tool_error_with_its_code(app, tool):
    assert failure(call(app, tool, deck_id=MISSING, **DECK_TOOLS[tool])) == "no-such-deck"


def test_get_format_rules_for_an_unknown_format_is_a_tool_error(app):
    assert failure(call(app, "get_format_rules", format="nope")) == "unknown-format"


def test_get_card_that_matches_nothing_is_a_tool_error(app):
    assert failure(call(app, "get_card", oracle_id_or_name="Zzyzx Not A Card")) == "no-such-card"


def test_search_cards_failing_is_a_tool_error(app, monkeypatch, tmp_path):
    monkeypatch.setenv("KP_CATALOG", str(tmp_path / "missing.sqlite"))
    from catalog import store

    store.reset()
    assert failure(call(app, "search_cards", query="bolt")) == "card-search-failed"


def test_deck_create_with_a_blank_name_is_a_tool_error(app):
    assert failure(call(app, "deck_create", name="  ")) == "blank-name"


def test_deck_edit_refusing_a_rename_is_a_tool_error(app, deck_id):
    assert failure(call(app, "deck_edit", deck_id=deck_id, name=" ")) == "blank-name"


def test_a_successful_tool_is_not_an_error(app, deck_id):
    assert data(call(app, "deck_get", deck_id=deck_id))["name"] == "Burn"
    assert [d["name"] for d in data(call(app, "deck_list"))] == ["Burn"]
    assert data(call(app, "deck_browse")) == []


@pytest.fixture
def conflicting(monkeypatch):
    """Every commit meets another writer, so every call ends in try-again."""
    from jaclang.server.session import Session

    def conflict(self, anchor=None):
        raise WriteConflict(anchor_id=uuid4())

    monkeypatch.setattr(Session, "commit", conflict)


@pytest.mark.parametrize("tool", ["deck_list", "deck_browse", "get_card", "search_cards", "resolve_names", "deck_get", "deck_edit", "deck_create"])
def test_a_call_the_runner_could_not_finish_is_a_tool_error_with_try_again(app, deck_id, conflicting, tool):
    arguments = {
        "get_card": {"oracle_id_or_name": "Shock"}, "search_cards": {"query": "bolt"},
        "resolve_names": {"names": ["Shock"]}, "deck_get": {"deck_id": deck_id},
        "deck_edit": {"deck_id": deck_id, "name": "Renamed"}, "deck_create": {"name": "Another"},
    }.get(tool, {})
    assert failure(call(app, tool, **arguments)) == "try-again"
