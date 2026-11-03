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
