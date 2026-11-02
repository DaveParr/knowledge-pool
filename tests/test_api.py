"""API tests: decks over REST, and decks survive a server restart."""

from jaclang.runtimelib.testing import JacTestClient


def _deck_names(client: JacTestClient) -> list[str]:
    resp = client.post("/walker/ListDecks")
    assert resp.ok, resp.json()
    return [d["name"] for d in resp.json()["data"]["reports"][0]]


def test_create_and_list_decks(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        resp = client.post("/walker/CreateDeck", json={"name": "Izzet Tempo"})
        assert resp.ok, resp.json()
        assert _deck_names(client) == ["Izzet Tempo"]
    finally:
        client.close()


def test_blank_name_creates_nothing(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        resp = client.post("/walker/CreateDeck", json={"name": "   "})
        assert resp.json()["data"]["reports"] == []
        assert _deck_names(client) == []
    finally:
        client.close()


def test_decks_survive_restart(tmp_path):
    first = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    first.post("/walker/CreateDeck", json={"name": "Golgari Food"})
    first.close()

    second = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        assert _deck_names(second) == ["Golgari Food"]
    finally:
        second.close()
