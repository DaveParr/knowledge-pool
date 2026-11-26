"""The MCP tools called in process (`mcp_tools.jac`), with no server built, as the
connector calls them, on the local user. Every failure reaches the caller the
same way: a tool error (`is_error`) whose structured content is `{error, code}`.
Transport, the tool list and MCP Apps wiring are checked in `test_mcp.py`."""

import inspect
from types import SimpleNamespace
from unittest.mock import MagicMock
from uuid import uuid4

import pytest
from jaclang.runtime.exceptions import WriteConflict
from jaclang.testing.testing import JacTestClient
from mcp.server.mcpserver import Context

pytestmark = pytest.mark.usefixtures("jac_db_url")

MISSING = "no-such-deck-id"
APPS = SimpleNamespace(extensions={"io.modelcontextprotocol/ui": {"mimeTypes": ["text/html;profile=mcp-app"]}})


@pytest.fixture
def tools(tmp_path):
    # Imported first, so the app's modules and the tools' are the same ones.
    import mcp_tools

    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    # The first request sets Jac up on the test's database in this process.
    assert client.get("/healthz").status_code == 200
    try:
        yield mcp_tools
    finally:
        client.close()


def client_context(capabilities=None):
    """What a tool is given of its caller: a context whose client does, or does not, render MCP Apps."""
    ctx = MagicMock(spec=Context)
    ctx.client_capabilities = capabilities
    return ctx


def call(tools, tool, apps=False, **arguments):
    """The tool as the server registers it: through `adapted`, so its result is a CallToolResult."""
    function = getattr(tools, tool)
    if "ctx" in inspect.signature(function).parameters:
        arguments["ctx"] = client_context(APPS if apps else None)
    return tools.adapted(function)(**arguments)


def failure(result):
    assert result.is_error, result
    assert set(result.structured_content) == {"error", "code"}, result.structured_content
    assert result.content[0].text == result.structured_content["error"]
    return result.structured_content["code"]


def data(result):
    assert not result.is_error, result
    sc = result.structured_content
    return sc["result"] if set(sc) == {"result"} else sc


def text(result):
    assert not result.is_error, result
    return result.content[0].text


def oracle_id(tools, name):
    return data(call(tools, "resolve_names", names=[name]))["exact"][0]["oracle_id"]


def change(tools, name, count, zone="main", **more):
    return {"oracle_id": oracle_id(tools, name), "count": count, "zone": zone, "reason": "test", **more}


def main_counts(deck):
    return {c["name"]: c["count"] for c in deck["cards"] if c["zone"] == "main"}


@pytest.fixture
def deck_id(tools):
    return data(call(tools, "deck_create", name="Burn", format="modern"))["id"]


@pytest.fixture
def burn_id(tools):
    made = call(tools, "deck_create", name="Burn", format="modern", cards=[
        change(tools, "Lightning Bolt", 4), change(tools, "Goblin Guide", 4), change(tools, "Mountain", 52),
    ])
    return data(made)["id"]


def test_importing_the_tools_does_not_build_the_server(tools):
    assert not any(type(v).__name__ == "MCPServer" for v in vars(tools).values())


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
def test_deck_tool_on_an_unknown_deck_is_a_tool_error_with_its_code(tools, tool):
    assert failure(call(tools, tool, deck_id=MISSING, **DECK_TOOLS[tool])) == "no-such-deck"


def test_get_format_rules_for_an_unknown_format_is_a_tool_error(tools):
    assert failure(call(tools, "get_format_rules", format="nope")) == "unknown-format"


def test_get_card_that_matches_nothing_is_a_tool_error(tools):
    assert failure(call(tools, "get_card", oracle_id_or_name="Zzyzx Not A Card")) == "no-such-card"


def test_search_cards_failing_is_a_tool_error(tools, monkeypatch, tmp_path):
    monkeypatch.setenv("KP_CATALOG", str(tmp_path / "missing.sqlite"))
    from catalog import store

    store.reset()
    assert failure(call(tools, "search_cards", query="bolt")) == "card-search-failed"


def test_deck_create_with_a_blank_name_is_a_tool_error(tools):
    assert failure(call(tools, "deck_create", name="  ")) == "blank-name"


def test_deck_edit_refusing_a_rename_is_a_tool_error(tools, deck_id):
    assert failure(call(tools, "deck_edit", deck_id=deck_id, name=" ")) == "blank-name"


def test_deck_import_in_an_unknown_list_format_is_a_tool_error(tools, deck_id):
    assert failure(call(tools, "deck_import", deck_id=deck_id, format="cockatrice", text="1 Shock")) == "unknown-list-format"


def test_deck_export_in_an_unknown_list_format_is_a_tool_error(tools, deck_id):
    assert failure(call(tools, "deck_export", deck_id=deck_id, format="cockatrice")) == "unknown-list-format"


def test_a_failure_never_raises_out_of_a_tool(tools):
    result = call(tools, "deck_get", deck_id=MISSING)
    assert result.is_error and result.content[0].text == f"No deck with id {MISSING}."


# What a tool gives when it works.

def test_search_cards_returns_lightning_bolt_for_its_name(tools):
    hits = data(call(tools, "search_cards", query="lightning bolt", limit=5))
    assert "Lightning Bolt" in [h["name"] for h in hits]


def test_get_card_by_name_returns_the_card_with_its_keywords(tools):
    assert data(call(tools, "get_card", oracle_id_or_name="Delver of Secrets"))["keywords"] == ["Flying", "Transform"]


def test_resolve_names_sorts_exact_fuzzy_and_unknown(tools):
    got = data(call(tools, "resolve_names", names=["Lightning Bolt", "Lightening Bolt", "Flargle the Unreal"]))
    assert [e["name"] for e in got["exact"]] == ["Lightning Bolt"]
    assert got["fuzzy"][0]["candidates"][0]["name"] == "Lightning Bolt"
    assert got["unknown"] == ["Flargle the Unreal"]


def test_get_format_rules_for_modern_gives_sixty_cards_four_copies_fifteen_sideboard(tools):
    rules = data(call(tools, "get_format_rules", format="modern"))
    assert (rules["min_main"], rules["copy_limit"], rules["sideboard_max"]) == (60, 4, 15)


def test_deck_create_with_cards_returns_the_deck_in_one_step(tools, burn_id):
    deck = data(call(tools, "deck_get", deck_id=burn_id))
    assert main_counts(deck) == {"Lightning Bolt": 4, "Goblin Guide": 4, "Mountain": 52}
    assert deck["legal"] is True


def test_a_successful_tool_is_not_an_error(tools, deck_id):
    assert data(call(tools, "deck_get", deck_id=deck_id))["name"] == "Burn"
    assert [d["name"] for d in data(call(tools, "deck_list"))] == ["Burn"]
    assert data(call(tools, "deck_browse")) == []


def test_deck_list_gives_id_name_and_format_only(tools, deck_id):
    assert data(call(tools, "deck_list")) == [{"id": deck_id, "name": "Burn", "format": "modern"}]


def test_deck_edit_adds_on_top_of_the_count_and_renames_in_one_call(tools, burn_id):
    deck = data(call(
        tools, "deck_edit", deck_id=burn_id, name=" Burn v2 ",
        changes=[change(tools, "Lightning Bolt", 1, mode="add")],
    ))
    assert main_counts(deck)["Lightning Bolt"] == 5
    assert deck["name"] == "Burn v2"


def test_deck_edit_lists_rejected_changes_and_applies_the_rest(tools, deck_id):
    deck = data(call(tools, "deck_edit", deck_id=deck_id, changes=[
        change(tools, "Mountain", 3), {"oracle_id": "made-up-id", "count": 1, "zone": "main", "reason": "invented"},
    ]))
    assert main_counts(deck) == {"Mountain": 3}
    assert len(deck["rejected"]) == 1


def test_deck_validate_says_legal_and_has_no_game_changers_outside_commander(tools, burn_id):
    verdict = data(call(tools, "deck_validate", deck_id=burn_id))
    assert verdict["legal"] is True and verdict["violations"] == [] and verdict["game_changers"] is None


def test_deck_copy_makes_the_callers_own_copy(tools, burn_id):
    copied = data(call(tools, "deck_copy", deck_id=burn_id))
    assert copied["name"] == "Burn (copy)" and copied["id"] != burn_id


def test_deck_import_of_a_text_list_fills_the_deck_and_lists_what_did_not_resolve(tools, deck_id):
    done = data(call(tools, "deck_import", deck_id=deck_id, format="text", text="4 Lightning Bolt\n1 Flargle"))
    assert done["deck"]["main_total"] == 4 and len(done["unresolved"]) == 1


def test_deck_export_round_trips_through_deck_import(tools, burn_id):
    exported = data(call(tools, "deck_export", deck_id=burn_id, format="mtgdeck1", apps=True))
    other = data(call(tools, "deck_create", name="Other", format="modern"))["id"]
    done = data(call(tools, "deck_import", deck_id=other, format="mtgdeck1", text=exported["content"]))
    assert done["unresolved"] == [] and done["deck"]["main_total"] == 60


# View tools: structured content for a client that renders MCP Apps, Markdown for one that does not.

def test_deck_show_gives_a_client_without_apps_markdown_and_no_structured_content(tools, burn_id):
    shown = call(tools, "deck_show", deck_id=burn_id)
    assert shown.structured_content is None
    assert "| 4 (0 owned) | Goblin Guide | {R} | Creature — Goblin Scout | 2/2 |" in text(shown)


def test_deck_get_and_deck_show_carry_the_collection_counts_missing_cards_and_sleeveable(tools, burn_id):
    bolt = oracle_id(tools, "Lightning Bolt")
    data(call(tools, "collection_change", oracle_id=bolt, count=3, reason="test"))
    deck = data(call(tools, "deck_get", deck_id=burn_id))
    assert {c["name"]: c["collection_count"] for c in deck["cards"]}["Lightning Bolt"] == 3
    missing = {m["name"]: m["count"] for m in deck["missing"]}
    assert missing["Lightning Bolt"] == 1 and missing["Goblin Guide"] == 4
    assert deck["sleeveable"] is False
    shown = text(call(tools, "deck_show", deck_id=burn_id))
    assert "| 4 (3 owned) | Lightning Bolt |" in shown
    assert "Not sleeveable: missing" in shown


def test_deck_show_gives_an_apps_client_a_brief_and_the_deck(tools, burn_id):
    shown = call(tools, "deck_show", deck_id=burn_id, apps=True)
    assert text(shown).startswith("Shown to the user as an expandable deck list: Burn")
    assert shown.structured_content["main_total"] == 60


def test_deck_analyze_gives_markdown_or_the_analysis_only(tools, burn_id):
    plain_client = call(tools, "deck_analyze", deck_id=burn_id)
    assert plain_client.structured_content is None and "| Red | 8 | 52 |" in text(plain_client)
    apps = call(tools, "deck_analyze", deck_id=burn_id, apps=True)
    assert set(apps.structured_content) == {"id", "name", "format", "main_total", "mana", "curve"}
    assert "|" not in text(apps)


def test_card_search_shows_what_the_deck_holds_and_whether_it_is_mine(tools, burn_id):
    found = call(tools, "card_search", deck_id=burn_id, query="lightning bolt", apps=True)
    bolt = next(h for h in found.structured_content["hits"] if h["name"] == "Lightning Bolt")
    assert bolt["in_deck"] == {"main": 4}
    assert found.structured_content["deck"]["mine"] is True
    assert "| In deck |" in text(call(tools, "card_search", deck_id=burn_id, query="lightning bolt"))


def test_card_search_hits_carry_the_deck_owners_collection_count(tools, burn_id):
    call(tools, "collection_change", oracle_id=oracle_id(tools, "Lightning Bolt"), count=2, reason="test")
    found = call(tools, "card_search", deck_id=burn_id, query="lightning", apps=True)
    owned = {h["name"]: h["owned"] for h in found.structured_content["hits"]}
    assert owned["Lightning Bolt"] == 2 and owned["Ball Lightning"] == 0


def test_card_search_owned_only_keeps_cards_in_the_deck_owners_collection(tools, burn_id):
    call(tools, "collection_change", oracle_id=oracle_id(tools, "Lightning Bolt"), count=2, reason="test")
    found = call(tools, "card_search", deck_id=burn_id, query="lightning", owned_only=True, apps=True)
    assert [(h["name"], h["owned"], h["in_deck"]) for h in found.structured_content["hits"]] == [("Lightning Bolt", 2, {"main": 4})]


def test_card_search_markdown_has_an_owned_column(tools, burn_id):
    call(tools, "collection_change", oracle_id=oracle_id(tools, "Lightning Bolt"), count=2, reason="test")
    table = text(call(tools, "card_search", deck_id=burn_id, query="lightning bolt"))
    assert "| In deck | Owned |" in table and "| 4 main | 2 |" in table


def test_search_cards_owned_only_keeps_cards_in_your_collection(tools):
    call(tools, "collection_change", oracle_id=oracle_id(tools, "Ball Lightning"), count=1, reason="test")
    names = [h["name"] for h in data(call(tools, "search_cards", query="lightning", owned_only=True))]
    assert names == ["Ball Lightning"]


def test_search_cards_without_owned_only_is_the_plain_catalogue_search(tools):
    call(tools, "collection_change", oracle_id=oracle_id(tools, "Ball Lightning"), count=1, reason="test")
    hits = data(call(tools, "search_cards", query="lightning"))
    assert {"Lightning Bolt", "Ball Lightning"} <= {h["name"] for h in hits}
    assert all("owned" not in h for h in hits)


def test_card_search_with_no_match_is_not_an_error(tools, burn_id):
    none = call(tools, "card_search", deck_id=burn_id, query="zzqxv")
    assert not none.is_error and text(none).startswith("No cards match")


def test_deck_export_gives_a_client_without_apps_the_list_in_text(tools, burn_id):
    exported = call(tools, "deck_export", deck_id=burn_id)
    assert exported.structured_content is None
    assert text(exported).startswith("Exported Burn as MTGA/MTGO.") and "4 Lightning Bolt" in text(exported)


def test_deck_export_gives_an_apps_client_the_view_data(tools, burn_id):
    exported = call(tools, "deck_export", deck_id=burn_id, apps=True)
    sc = exported.structured_content
    assert (sc["format"], sc["name"], sc["deck_id"]) == ("arena", "Burn", burn_id)
    assert text(exported).startswith("Shown to the user in the export view")


@pytest.fixture
def conflicting(monkeypatch):
    """Every commit meets another writer, so every call ends in try-again."""
    from jaclang.server.session import Session

    def conflict(self, anchor=None):
        raise WriteConflict(anchor_id=uuid4())

    monkeypatch.setattr(Session, "commit", conflict)


@pytest.mark.parametrize("tool", ["deck_list", "deck_browse", "get_card", "search_cards", "resolve_names", "deck_get", "deck_edit", "deck_create", "user_list"])
# `others_deck_id` makes a second user: listing users has nothing to read (and so cannot conflict) without one.
def test_a_call_the_runner_could_not_finish_is_a_tool_error_with_try_again(tools, deck_id, others_deck_id, conflicting, tool):
    arguments = {
        "get_card": {"oracle_id_or_name": "Shock"}, "search_cards": {"query": "bolt"},
        "resolve_names": {"names": ["Shock"]}, "deck_get": {"deck_id": deck_id},
        "deck_edit": {"deck_id": deck_id, "name": "Renamed"}, "deck_create": {"name": "Another"},
    }.get(tool, {})
    assert failure(call(tools, tool, **arguments)) == "try-again"


# What the smoke script used to check through the transport.

def test_commander_rules_say_exactly_100_and_singleton(tools):
    rules = data(call(tools, "get_format_rules", format="commander"))
    assert (rules["min_main"], rules["copy_limit"], rules["exact_size"]) == (100, 1, True)


@pytest.fixture
def commander_id(tools):
    made = call(tools, "deck_create", name="Krenko", format="commander", cards=[
        change(tools, "Krenko, Mob Boss", 1, "commander"), change(tools, "Rhystic Study", 1),
        change(tools, "Mountain", 97),
    ])
    return data(made)["id"]


def test_deck_validate_names_a_commander_decks_game_changers(tools, commander_id):
    verdict = data(call(tools, "deck_validate", deck_id=commander_id))
    assert verdict["legal"] is False and "deck-size" in [v["rule"] for v in verdict["violations"]]
    assert verdict["game_changers"]["count"] == 1


def test_deck_show_names_the_game_changers_and_has_a_commander_heading(tools, commander_id):
    shown = text(call(tools, "deck_show", deck_id=commander_id))
    assert "Game Changers: 1 (Rhystic Study)" in shown and "### Commander" in shown


def test_deck_edit_keeps_the_curve_through_a_format_change_and_logs_each_reason(tools, burn_id):
    deck = data(call(tools, "deck_get", deck_id=burn_id))
    assert deck["curve"]["buckets"]["1"] == 8 and deck["curve"]["average_mv"] == 1.0
    switched = data(call(tools, "deck_edit", deck_id=burn_id, format="standard"))
    assert switched["curve"] == deck["curve"]
    verdict = data(call(tools, "deck_validate", deck_id=burn_id))
    assert not verdict["legal"] and {v["rule"] for v in verdict["violations"]} == {"not-legal"}


def test_a_refused_rename_leaves_the_cards_unchanged(tools, burn_id):
    refused = call(tools, "deck_edit", deck_id=burn_id, name="  ", changes=[change(tools, "Lightning Bolt", 1, mode="add")])
    assert failure(refused) == "blank-name"
    assert main_counts(data(call(tools, "deck_get", deck_id=burn_id)))["Lightning Bolt"] == 4


@pytest.fixture
def others_deck_id(tools):
    """A deck of another user, made through the runner as that user."""
    from decks import CreateDeck
    from deck_operations import perform

    done = perform("someone-else", CreateDeck(name="Theirs", format="modern", changes=[]))
    return tools.plain(done.reports[0])["id"]


def test_deck_browse_lists_another_users_deck_with_its_owner_and_not_my_own(tools, deck_id, others_deck_id):
    browsed = data(call(tools, "deck_browse"))
    assert [(d["id"], d["name"], d["format"]) for d in browsed] == [(others_deck_id, "Theirs", "modern")]
    assert "owner" in browsed[0]


def test_deck_copy_of_another_users_deck_is_my_own_copy_and_not_theirs_to_change_back(tools, others_deck_id):
    copied = data(call(tools, "deck_copy", deck_id=others_deck_id))
    assert copied["name"] == "Theirs (copy)" and copied["id"] != others_deck_id


def test_deck_edit_of_another_users_deck_is_a_tool_error_with_not_your_deck(tools, others_deck_id):
    assert failure(call(tools, "deck_edit", deck_id=others_deck_id, name="Mine now")) == "not-your-deck"


def test_collection_change_adds_removes_and_sets_counts_and_collection_get_reads_them(tools):
    bolt = oracle_id(tools, "Lightning Bolt")
    added = data(call(tools, "collection_change", oracle_id=bolt, count=4, mode="add", reason="bought at FNM"))
    assert [(c["name"], c["count"]) for c in added["cards"]] == [("Lightning Bolt", 4)]
    data(call(tools, "collection_change", oracle_id=bolt, count=1, mode="remove", reason="traded"))
    assert data(call(tools, "collection_get"))["cards"][0]["count"] == 3
    done = data(call(tools, "collection_change", oracle_id=bolt, count=0, mode="set", reason="sold the lot"))
    assert done["cards"] == []
    assert [n["reason"] for n in done["history"]] == ["bought at FNM", "traded", "sold the lot"]


def test_collection_change_removing_more_than_held_is_a_tool_error_that_says_how_many_are_held(tools):
    bolt = oracle_id(tools, "Lightning Bolt")
    data(call(tools, "collection_change", oracle_id=bolt, count=2, reason="test"))
    result = call(tools, "collection_change", oracle_id=bolt, count=3, mode="remove", reason="test")
    assert failure(result) == "refused-change"
    assert "2" in result.content[0].text


@pytest.fixture
def others_collection(tools):
    """Another user's collection of two Lightning Bolts, with a display name set, made through the runner as that user."""
    from collection import ChangeCollection
    from deck_operations import perform
    from graph_runner import call_function
    from profile import save_display_name

    call_function("someone-else", lambda: save_display_name("Sam Other") or None)
    perform("someone-else", ChangeCollection(oracle_id=oracle_id(tools, "Lightning Bolt"), count=2, reason="for trade"))


def sam_handle(tools):
    return [u["handle"] for u in data(call(tools, "user_list")) if u["name"] == "Sam Other"][0]


def test_user_list_names_other_users_by_handle_and_display_name_and_never_by_email(tools, others_collection):
    listed = data(call(tools, "user_list"))
    sam = [u for u in listed if u["name"] == "Sam Other"]
    assert len(sam) == 1
    assert all(set(u) == {"handle", "name"} for u in listed)
    assert all("@" not in u["handle"] and "someone-else" not in u["handle"] for u in listed)


def test_collection_browse_reads_another_users_collection_by_handle(tools, others_collection):
    handle = sam_handle(tools)
    seen = data(call(tools, "collection_browse", handle=handle))
    assert [(c["name"], c["count"]) for c in seen["cards"]] == [("Lightning Bolt", 2)]
    assert seen["history"][-1]["reason"] == "for trade"


def test_collection_browse_of_an_unknown_handle_is_a_tool_error_with_no_such_user(tools):
    assert failure(call(tools, "collection_browse", handle="nope")) == "no-such-user"

def test_collection_import_adds_a_pasted_list_and_reports_names_that_resolve_to_no_card(tools):
    result = data(call(tools, "collection_import", format="text", text="4 Lightning Bolt\n\nSideboard\n1 Lightning Bolt\n2 Not A Real Card\n"))
    assert [(c["name"], c["count"]) for c in result["collection"]["cards"]] == [("Lightning Bolt", 5)]
    assert any("Not A Real Card" in line for line in result["unresolved"])
    assert result["collection"]["history"][-1]["reason"] == "imported"
    assert data(call(tools, "collection_get"))["cards"][0]["count"] == 5


def test_collection_import_of_an_unknown_format_is_a_tool_error(tools):
    assert failure(call(tools, "collection_import", format="nope", text="1 Shock")) == "unknown-list-format"
