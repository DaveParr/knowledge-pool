"""The mana curve on DeckView, end to end through the catalogue and REST API.

Every walker that reports a deck reports its curve, so the deck view needs one
request per edit."""

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


def _buckets(**counts) -> dict:
    out = {b: 0 for b in ["0", "1", "2", "3", "4", "5", "6", "7+"]}
    out.update({k.removeprefix("mv"): v for k, v in counts.items()})
    return out


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

        curve = _reports(client.post("/walker/GetDeck", json={"deck_id": deck_id}))[0]["curve"]

        assert curve["buckets"] == _buckets(mv0=1, mv1=4, mv3=1)
        assert curve["average_mv"] == 1.17
    finally:
        client.close()


def test_curve_is_zero_for_an_all_land_deck(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client, "All land")
        mountain = _oracle_id("Mountain")
        view = _reports(
            client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": mountain, "count": 40})
        )[0]

        assert view["curve"]["buckets"] == _buckets()
        assert view["curve"]["average_mv"] == 0.0
    finally:
        client.close()


def test_every_edit_reports_the_curve_after_that_edit(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        bolt = _oracle_id("Lightning Bolt")
        fireball = _oracle_id("Fireball")

        added = _reports(client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": bolt, "count": 4}))[0]
        assert added["curve"]["buckets"] == _buckets(mv1=4)

        counted = _reports(
            client.post("/walker/SetCardCount", json={"deck_id": deck_id, "oracle_id": bolt, "count": 2})
        )[0]
        assert counted["curve"]["buckets"] == _buckets(mv1=2)

        _reports(client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": fireball, "count": 1}))
        removed = _reports(
            client.post("/walker/RemoveCard", json={"deck_id": deck_id, "oracle_id": bolt})
        )[0]
        # The fixture catalogue gives Fireball ({X}{R}) mana value 0.
        assert removed["curve"]["buckets"] == _buckets(mv0=1)

        reformatted = _reports(
            client.post("/walker/SetDeckFormat", json={"deck_id": deck_id, "format": "modern"})
        )[0]
        assert reformatted["format"] == "modern"
        assert reformatted["curve"]["buckets"] == _buckets(mv0=1)

        text = "4 Lightning Bolt\n2 Fireball\n"
        imported = _reports(
            client.post("/walker/DeckImport", json={"deck_id": deck_id, "format": "text", "text": text})
        )[0]
        assert imported["deck"]["curve"]["buckets"] == _buckets(mv0=2, mv1=4)
        assert imported["deck"]["curve"]["average_mv"] == 0.67
    finally:
        client.close()


def test_the_analyze_deck_walker_is_gone(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        resp = client.post("/walker/AnalyzeDeck", json={"deck_id": deck_id})
        assert resp.status_code == 404 or not resp.json().get("ok"), resp.json()
    finally:
        client.close()
