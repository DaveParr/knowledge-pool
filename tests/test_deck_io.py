import json

from jaclang.runtimelib.testing import JacTestClient

from catalog import store


def _reports(resp):
    body = resp.json()
    assert body["ok"], body
    return body["data"]["reports"]


def _oracle_id(name: str) -> str:
    return next(c["oracle_id"] for c in store.search(name) if c["name"] == name)


def _new_deck(client, name="IO deck", format="modern") -> str:
    _reports(client.post("/walker/CreateDeck", json={"name": name, "format": format}))
    return _reports(client.post("/walker/ListDecks"))[0][-1]["_jac_id"]


def test_export_mtgdeck1_contains_every_card_in_the_right_zone(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": _oracle_id("Lightning Bolt"), "count": 4})
        client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": _oracle_id("Mountain"), "count": 20, "zone": "sideboard"})

        exported = _reports(client.post("/walker/DeckExport", json={"deck_id": deck_id, "format": "mtgdeck1"}))[0]
        doc = json.loads(exported["content"])
        assert doc["schema"] == "mtgdeck/1"
        assert {e["name"]: e["count"] for e in doc["zones"]["main"]} == {"Lightning Bolt": 4}
        assert {e["name"]: e["count"] for e in doc["zones"]["sideboard"]} == {"Mountain": 20}
    finally:
        client.close()


def test_export_with_an_unknown_format_reports_nothing(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        assert _reports(client.post("/walker/DeckExport", json={"deck_id": deck_id, "format": "nope"})) == []
    finally:
        client.close()


def test_export_mtgdeck1_then_import_round_trips(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": _oracle_id("Lightning Bolt"), "count": 4})
        client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": _oracle_id("Mountain"), "count": 20, "zone": "sideboard"})
        exported = _reports(client.post("/walker/DeckExport", json={"deck_id": deck_id, "format": "mtgdeck1"}))[0]

        imported = _reports(client.post("/walker/DeckImport", json={
            "deck_id": deck_id, "format": "mtgdeck1", "text": exported["content"],
        }))[0]
        assert imported["unresolved"] == []
        cards = {(c["name"], c["zone"]): c["count"] for c in imported["deck"]["cards"]}
        assert cards == {("Lightning Bolt", "main"): 4, ("Mountain", "sideboard"): 20}
    finally:
        client.close()


def test_import_flags_unresolved_lines_and_never_invents_a_card(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        result = _reports(client.post("/walker/DeckImport", json={
            "deck_id": deck_id, "format": "text",
            "text": "4 Lightning Bolt\n2 Flargle the Unreal\n",
        }))[0]
        assert result["unresolved"] == ["Flargle the Unreal"]
        assert [c["name"] for c in result["deck"]["cards"]] == ["Lightning Bolt"]
    finally:
        client.close()


def test_importing_a_new_list_replaces_what_was_there_before(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": _oracle_id("Goblin Guide"), "count": 4})
        result = _reports(client.post("/walker/DeckImport", json={
            "deck_id": deck_id, "format": "text", "text": "4 Lightning Bolt\n",
        }))[0]
        assert [c["name"] for c in result["deck"]["cards"]] == ["Lightning Bolt"]
    finally:
        client.close()


def test_commander_zone_entries_do_not_count_toward_main_deck_legality(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client, format="modern")
        text = json.dumps({
            "schema": "mtgdeck/1", "name": "cmdr test", "format": "modern",
            "zones": {
                "commander": [{"name": "Lightning Bolt", "count": 1}],
                "main": [{"name": "Mountain", "count": 60}],
            },
        })
        result = _reports(client.post("/walker/DeckImport", json={"deck_id": deck_id, "format": "mtgdeck1", "text": text}))[0]
        assert result["unresolved"] == []
        view = _reports(client.post("/walker/GetDeck", json={"deck_id": deck_id}))[0]
        assert view["legal"] is True
        assert view["main_total"] == 60
    finally:
        client.close()


def test_import_with_an_unknown_format_reports_nothing(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        assert _reports(client.post("/walker/DeckImport", json={"deck_id": deck_id, "format": "nope", "text": ""})) == []
    finally:
        client.close()


def test_import_flags_an_invalid_zone_instead_of_bricking_the_deck(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": _oracle_id("Goblin Guide"), "count": 4})
        text = json.dumps({
            "schema": "mtgdeck/1", "name": "bad zone test", "format": "modern",
            "zones": {
                "bogus_zone": [{"name": "Mountain", "count": 1}],
                "main": [{"name": "Lightning Bolt", "count": 4}],
            },
        })
        result = _reports(client.post("/walker/DeckImport", json={"deck_id": deck_id, "format": "mtgdeck1", "text": text}))[0]
        assert result["unresolved"] == ["Mountain"]
        assert [c["name"] for c in result["deck"]["cards"]] == ["Lightning Bolt"]

        # The deck must still be readable afterwards - a bad zone entry must
        # never be persisted onto the deck.
        view = _reports(client.post("/walker/GetDeck", json={"deck_id": deck_id}))[0]
        assert [c["name"] for c in view["cards"]] == ["Lightning Bolt"]
    finally:
        client.close()
