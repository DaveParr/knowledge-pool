"""Add, change and remove cards on a deck over REST, and survive a restart."""

import sqlite3

from jaclang.runtimelib.testing import JacTestClient

from catalog import store
from tests.old_catalog import drop_produced_mana


def _reports(resp):
    body = resp.json()
    assert body["ok"], body
    return body["data"]["reports"]


def _oracle_id(name: str) -> str:
    return next(c["oracle_id"] for c in store.search(name) if c["name"] == name)


def _new_deck(client, name="Test deck") -> str:
    _reports(client.post("/walker/CreateDeck", json={"name": name}))
    return _reports(client.post("/walker/ListDecks"))[0][-1]["_jac_id"]


def _lines(view) -> dict[str, int]:
    return {c["name"]: c["count"] for c in view["cards"]}


def test_search_endpoint_finds_real_cards(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        resp = client.post("/function/search_cards", json={"query": "deals 3 damage"})
        result = resp.json()["data"]["result"]
        assert "Lightning Bolt" in [c["name"] for c in result["hits"]]
        assert result["error"] == ""
    finally:
        client.close()


def test_search_endpoint_reports_a_catalogue_failure(tmp_path, fixture_catalog):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        # A catalogue built before `produced_mana` existed (#61).
        con = sqlite3.connect(fixture_catalog)
        drop_produced_mana(con)
        con.commit()
        con.close()
        store.reset()

        resp = client.post("/function/search_cards", json={"query": "bolt"})
        result = resp.json()["data"]["result"]
        assert result["hits"] == []
        assert "no such column: c.produced_mana" in result["error"]
    finally:
        client.close()


def test_add_change_remove(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        bolt, mountain = _oracle_id("Lightning Bolt"), _oracle_id("Mountain")

        view = _reports(client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": bolt, "count": 4}))[0]
        assert _lines(view) == {"Lightning Bolt": 4}

        view = _reports(client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": mountain, "count": 20}))[0]
        view = _reports(client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": mountain}))[0]
        assert _lines(view) == {"Lightning Bolt": 4, "Mountain": 21}
        assert view["main_total"] == 25

        view = _reports(client.post("/walker/SetCardCount", json={"deck_id": deck_id, "oracle_id": bolt, "count": 2}))[0]
        assert _lines(view)["Lightning Bolt"] == 2

        view = _reports(client.post("/walker/SetCardCount", json={"deck_id": deck_id, "oracle_id": bolt, "count": 0}))[0]
        assert _lines(view) == {"Mountain": 21}

        view = _reports(client.post("/walker/RemoveCard", json={"deck_id": deck_id, "oracle_id": mountain}))[0]
        assert view["cards"] == [] and view["main_total"] == 0
        # Web edits are logged like any other holdings change.
        assert [(h["name"], h["before"], h["after"]) for h in view["history"]][-2:] == [
            ("Lightning Bolt", 2, 0), ("Mountain", 21, 0),
        ]
        assert {h["reason"] for h in view["history"]} == {"Edited in the app"}
    finally:
        client.close()


def _error(reports: list) -> dict:
    [only] = reports
    return {k: only[k] for k in ("code", "message")}


def test_a_refused_change_reports_why(tmp_path):
    # Which changes are refused is tested on change_holding (tests/holdings_tests.jac);
    # this only checks the walkers pass the refusal on as their one report.
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        assert _error(_reports(client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": "not-a-card"}))) == {
            "code": "refused-change", "message": "Change refused: not-a-card is not a known oracle id.",
        }
        bolt = _oracle_id("Lightning Bolt")
        assert _error(_reports(client.post("/walker/SetCardCount", json={"deck_id": deck_id, "oracle_id": bolt, "count": -1}))) == {
            "code": "refused-change", "message": "Change refused: count must be a whole number, 0 or more.",
        }
        assert _error(_reports(client.post("/walker/RemoveCard", json={"deck_id": deck_id, "oracle_id": bolt, "zone": "attic"})))["code"] == "refused-change"
        assert _reports(client.post("/walker/GetDeck", json={"deck_id": deck_id}))[0]["cards"] == []
    finally:
        client.close()


def test_every_deck_walker_says_when_there_is_no_such_deck(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        bolt = _oracle_id("Lightning Bolt")
        for walker, body in [
            ("GetDeck", {}),
            ("AddCard", {"oracle_id": bolt}),
            ("SetCardCount", {"oracle_id": bolt, "count": 2}),
            ("RemoveCard", {"oracle_id": bolt}),
            ("SetDeckFormat", {"format": "modern"}),
            ("DeckExport", {"format": "text"}),
            ("DeckImport", {"format": "text", "text": "4 Lightning Bolt"}),
        ]:
            for deck_id in ["nope", "0" * 32]:
                reports = _reports(client.post(f"/walker/{walker}", json={"deck_id": deck_id, **body}))
                assert _error(reports) == {"code": "no-such-deck", "message": f"No deck with id {deck_id}."}, walker
    finally:
        client.close()


def test_deck_view_carries_each_cards_oracle_tags(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        bolt, mountain = _oracle_id("Lightning Bolt"), _oracle_id("Mountain")
        client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": bolt})
        view = _reports(client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": mountain}))[0]

        by_name = {c["name"]: c["oracle_tags"] for c in view["cards"]}
        assert sorted(by_name["Lightning Bolt"]) == ["burn", "removal"]
        # A card with no taggings in the fixture gets an empty list, not an error.
        assert by_name["Mountain"] == []
    finally:
        client.close()


def test_two_decks_share_one_card_node(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        bolt = _oracle_id("Lightning Bolt")
        first = _new_deck(client, "First")
        second = _new_deck(client, "Second")
        a = _reports(client.post("/walker/AddCard", json={"deck_id": first, "oracle_id": bolt}))[0]
        b = _reports(client.post("/walker/AddCard", json={"deck_id": second, "oracle_id": bolt}))[0]
        assert _lines(a) == _lines(b) == {"Lightning Bolt": 1}
    finally:
        client.close()


def test_cards_in_a_deck_survive_restart(tmp_path):
    first = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    deck_id = _new_deck(first)
    _reports(first.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": _oracle_id("Goblin Guide"), "count": 4}))
    first.close()

    second = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        view = _reports(second.post("/walker/GetDeck", json={"deck_id": deck_id}))[0]
        assert _lines(view) == {"Goblin Guide": 4}
    finally:
        second.close()


def test_mana_analysis_in_deck_view(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        mountain = _oracle_id("Mountain")
        bolt = _oracle_id("Lightning Bolt")
        elves = _oracle_id("Llanowar Elves")
        forest = _oracle_id("Forest")

        client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": mountain, "count": 4})
        client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": bolt, "count": 2})
        client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": elves, "count": 1})
        # sideboard cards must not count towards lands, pips or sources
        client.post(
            "/walker/AddCard", json={"deck_id": deck_id, "oracle_id": forest, "count": 3, "zone": "sideboard"}
        )

        view = _reports(client.post("/walker/GetDeck", json={"deck_id": deck_id}))[0]
        mana = view["mana"]
        assert mana["land_count"] == 4
        assert mana["pips"] == {"W": 0, "U": 0, "B": 0, "R": 2, "G": 1}
        assert mana["sources"] == {"W": 0, "U": 0, "B": 0, "R": 4, "G": 1}
    finally:
        client.close()
