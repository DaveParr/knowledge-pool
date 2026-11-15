"""The front door over HTTP (Seam B): a test client drives the ASGI app that
`front_door.jac` builds, on this test's own database. Jac's server (the page's
child) is a stub that records what reaches it, so a test can say what the front
door did and did not forward."""

import re
from pathlib import Path

import pytest

import front_door
import graph_runner
from tests.front_door_client import ORIGIN, FrontDoorClient

ROOT = Path(__file__).resolve().parent.parent
pytestmark = pytest.mark.usefixtures("jac_db_url")

# Paths Jac's server answers by default that nothing outside may reach.
CLOSED_PATHS = [
    "/docs", "/openapi.json", "/graph", "/admin", "/walkers", "/functions", "/user/login", "/user/register",
    "/sso/google/start", "/cl/__error__", "/static/../docs", "/some/other/path",
]


@pytest.fixture
def client(tmp_path):
    with FrontDoorClient(tmp_path) as c:
        yield c


def test_health_answers_ok_for_any_host_without_reaching_jacs_server(client):
    for host in ("healthcheck.railway.app", "127.0.0.1:8123", "knowledge-pool.engi.ai"):
        reply = client.get("/healthz", headers={"host": host})
        assert (reply.status_code, reply.text) == (200, "ok")
    assert client.upstream_requests == []


@pytest.mark.parametrize("path", CLOSED_PATHS)
def test_closed_path_answers_404_and_never_reaches_jacs_server(client, path):
    assert client.get(path).status_code == 404
    assert client.post(path, json={}).status_code == 404
    assert client.upstream_requests == []


def test_data_paths_answer_404_to_anything_but_post(client):
    for path in ("/walker/ListDecks", "/function/list_formats"):
        assert client.get(path).status_code == 404
    assert client.upstream_requests == []


def test_page_and_static_files_come_from_jacs_server_without_credentials(client):
    page = client.get("/", headers={"cookie": "kp=secret", "authorization": "Bearer abc"})
    assert page.status_code == 200 and "<title>app</title>" in page.text
    static = client.get("/static/client.js?hash=1")
    assert static.status_code == 200 and static.headers["content-type"].startswith("text/javascript")
    assert [(r.url.path, r.url.query) for r in client.upstream_requests] == [("/", b""), ("/static/client.js", b"hash=1")]
    for seen in client.upstream_requests:
        assert "cookie" not in seen.headers and "authorization" not in seen.headers


def test_page_answers_502_when_jacs_server_is_gone(client):
    client.upstream_down()
    assert client.get("/").status_code == 502


def test_walker_call_answers_in_jacs_envelope_as_the_local_user(client):
    made = client.post("/walker/CreateDeck", json={"name": "Izzet Tempo"})
    assert made.status_code == 200
    assert made.json()["ok"] is True and made.json()["type"] == "response" and made.json()["error"] is None
    listed = client.post("/walker/ListDecks", json={}).json()
    [deck] = listed["data"]["reports"][0]
    assert deck["name"] == "Izzet Tempo" and deck["_jac_type"] == "Deck" and deck["_jac_id"]
    assert "result" in listed["data"]


def test_walker_error_is_the_walkers_one_report(client):
    reply = client.post("/walker/CreateDeck", json={"name": "   "}).json()
    [error] = reply["data"]["reports"]
    assert (error["code"], error["message"]) == ("blank-name", "A deck needs a name.")


def test_function_call_answers_in_jacs_envelope(client):
    formats = client.post("/function/list_formats", json={}).json()
    assert formats["ok"] is True
    assert "standard" in {f["name"] for f in formats["data"]["result"]}
    found = client.post("/function/search_cards", json={"query": "bolt", "limit": 3}).json()
    assert 0 < len(found["data"]["result"]["hits"]) <= 3


def test_unknown_walker_or_function_answers_404(client):
    assert client.post("/walker/DeckAction", json={}).status_code == 404
    assert client.post("/walker/EditDeck", json={}).status_code == 404
    assert client.post("/function/find_card", json={}).status_code == 404


@pytest.mark.parametrize("path, body", [
    ("/walker/ListDecks", {"user": "someone-else"}),
    ("/walker/CreateDeck", {}),
    ("/function/search_cards", {"nope": 1}),
    ("/walker/ListDecks", [1, 2]),
    ("/walker/ListDecks", {"reports": ["planted"]}),
])
def test_fields_that_do_not_fit_answer_422(client, path, body):
    assert client.post(path, json=body).status_code == 422


def test_data_call_with_a_foreign_or_missing_origin_answers_403(client):
    for headers in ({"origin": "http://evil.example"}, {"origin": "null"}, {}):
        reply = client.post("/walker/ListDecks", json={}, headers=headers, origin=None)
        assert reply.status_code == 403, headers
        assert reply.json()["ok"] is False
    assert client.post("/walker/ListDecks", json={}).status_code == 200


def test_hosted_mode_refuses_data_calls_without_a_caller(client, monkeypatch):
    monkeypatch.setenv("KP_MODE", "hosted")
    reply = client.post("/walker/ListDecks", json={})
    assert reply.status_code == 401 and reply.json()["error"]["code"] == "UNAUTHORIZED"
    assert client.post("/function/list_formats", json={}).status_code == 401
    assert client.get("/healthz").text == "ok"


def test_the_connectors_paths_go_to_the_mcp_app(client):
    assert client.get("/mcp").text == "mcp app: /mcp"
    assert client.get("/.well-known/oauth-protected-resource").text == "mcp app: /.well-known/oauth-protected-resource"


def test_a_call_that_still_conflicts_answers_503_try_again(client, monkeypatch):
    def conflicts(caller, f, name=""):
        raise graph_runner.CallFailed(error=graph_runner.try_again())

    monkeypatch.setattr(front_door, "call_function", conflicts)
    reply = client.post("/function/list_formats", json={})
    assert reply.status_code == 503 and reply.json()["error"]["code"] == "TRY-AGAIN"


def _protected_names() -> set[str]:
    """Every walker and function the app marks `:protect`, from the sources."""
    found: set[str] = set()
    for source in ("decks.jac", "deck_io.jac", "cards.jac", "legality.jac"):
        found |= set(re.findall(r"^(?:walker|def):protect (\w+)", (ROOT / source).read_text(), re.M))
    return found


def test_the_front_door_table_is_exactly_what_the_app_marks_protect():
    assert _protected_names() == set(front_door.WALKERS) | set(front_door.FUNCTIONS)


def test_no_walker_or_server_function_is_pub():
    """Jac's server would answer a `:pub` one for anyone who reaches it. (The page's own
    components and client helpers are `def:pub` too, in the client modules.)"""
    for name in ("decks.jac", "deck_io.jac", "cards.jac", "legality.jac"):
        assert not re.search(r"^(walker|def):pub ", (ROOT / name).read_text(), re.M), name
