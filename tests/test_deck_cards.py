"""Add, change and remove cards on a deck over REST, and survive a restart."""

from jaclang.runtimelib.testing import JacTestClient

from catalog import store


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
        names = [c["name"] for c in resp.json()["data"]["result"]]
        assert "Lightning Bolt" in names
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
    finally:
        client.close()


def test_unknown_card_or_bad_count_changes_nothing(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        assert _reports(client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": "not-a-card"})) == []
        bolt = _oracle_id("Lightning Bolt")
        assert _reports(client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": bolt, "count": 0})) == []
        assert _reports(client.post("/walker/SetCardCount", json={"deck_id": deck_id, "oracle_id": bolt, "count": -1})) == []
        assert _reports(client.post("/walker/GetDeck", json={"deck_id": deck_id}))[0]["cards"] == []
        assert _reports(client.post("/walker/GetDeck", json={"deck_id": "nope"})) == []
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


def test_mana_analysis_in_deck_view_and_analyze_deck(tmp_path):
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

        analysis = _reports(client.post("/walker/AnalyzeDeck", json={"deck_id": deck_id}))[0]
        assert analysis["mana"]["land_count"] == mana["land_count"]
        assert analysis["mana"]["pips"] == mana["pips"]
        assert analysis["mana"]["sources"] == mana["sources"]
    finally:
        client.close()
