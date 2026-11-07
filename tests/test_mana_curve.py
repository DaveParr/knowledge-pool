"""AnalyzeDeck's mana curve, end to end through the catalogue and REST API."""

from jaclang.runtimelib.testing import JacTestClient

from catalog import store


def _reports(resp):
    body = resp.json()
    assert body["ok"], body
    return body["data"]["reports"]


def _oracle_id(name: str) -> str:
    return next(c["oracle_id"] for c in store.search(name) if c["name"] == name)


def _new_deck(client, name="Curve deck") -> str:
    _reports(client.post("/walker/CreateDeck", json={"name": name}))
    return _reports(client.post("/walker/ListDecks"))[0][-1]["_jac_id"]


def test_curve_excludes_lands_and_sideboard_counts_x_spells_and_mdfcs(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        bolt = _oracle_id("Lightning Bolt")
        mountain = _oracle_id("Mountain")
        fireball = _oracle_id("Fireball")
        valakut = _oracle_id("Valakut Awakening // Valakut Stoneforge")

        _reports(client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": bolt, "count": 4}))
        _reports(client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": mountain, "count": 20}))
        _reports(client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": fireball, "count": 1}))
        _reports(client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": valakut, "count": 1}))
        _reports(
            client.post(
                "/walker/AddCard",
                json={"deck_id": deck_id, "oracle_id": bolt, "count": 2, "zone": "sideboard"},
            )
        )

        analysis = _reports(client.post("/walker/AnalyzeDeck", json={"deck_id": deck_id}))[0]
        curve = analysis["curve"]

        assert curve["buckets"] == {
            "0": 1, "1": 4, "2": 0, "3": 1, "4": 0, "5": 0, "6": 0, "7+": 0
        }
        assert curve["average_mv"] == 1.17
    finally:
        client.close()


def test_curve_is_zero_for_an_all_land_deck(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client, "All land")
        mountain = _oracle_id("Mountain")
        _reports(client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": mountain, "count": 40}))

        analysis = _reports(client.post("/walker/AnalyzeDeck", json={"deck_id": deck_id}))[0]
        curve = analysis["curve"]

        assert all(count == 0 for count in curve["buckets"].values())
        assert curve["average_mv"] == 0.0
    finally:
        client.close()


def test_analyze_deck_reports_nothing_for_unknown_deck(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        assert _reports(client.post("/walker/AnalyzeDeck", json={"deck_id": "nope"})) == []
    finally:
        client.close()
