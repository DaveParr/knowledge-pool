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


def _error(report: dict) -> dict:
    return {k: report[k] for k in ("code", "message")}


def test_blank_name_creates_nothing_and_says_why(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
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
    first = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    first.post("/walker/CreateDeck", json={"name": "Golgari Food"})
    first.close()

    second = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        assert _deck_names(second) == ["Golgari Food"]
    finally:
        second.close()
