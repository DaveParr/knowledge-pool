"""Browser sign-in and session through the front door (Seam B): a test client
drives the ASGI app in hosted mode, with a stand-in for WorkOS's sealed
session (`tests/hosted_sessions.py`). No test talks to WorkOS or Google."""

import re
from urllib.parse import parse_qs, quote, urlparse

import pytest

from tests.front_door_client import PUBLIC_ORIGIN, FrontDoorClient
from tests.hosted_sessions import LOGIN_URL, LOGOUT_URL, StandInSessions, sealed
from tests.hosted_tokens import TestIssuer

pytestmark = pytest.mark.usefixtures("jac_db_url")

ALICE = sealed("user_alice", "Alice Example")


@pytest.fixture
def sessions():
    return StandInSessions()


@pytest.fixture
def door(tmp_path, monkeypatch, sessions):
    issuer = TestIssuer()
    with FrontDoorClient(tmp_path, hosted=issuer, sessions=sessions, origin=PUBLIC_ORIGIN) as c:
        c.issuer = issuer
        monkeypatch.setenv("KP_MODE", "hosted")
        yield c


def _as(value: str) -> dict:
    return {"cookie": f"kp_session={value}"}


def _sign_in(door, code: str, return_to: str = "/") -> "httpx2.Response":
    """The browser's whole sign-in: the start, AuthKit's return with `code`."""
    start = door.get(f"/auth/login?return_to={quote(return_to, safe='')}")
    state = parse_qs(urlparse(start.headers["location"]).query)["state"][0]
    return door.get(f"/auth/callback?code={code}&state={state}")


def _set_cookies(reply) -> dict[str, str]:
    return {c.split("=", 1)[0]: c for c in reply.headers.get_list("set-cookie")}


def test_a_page_load_with_no_session_redirects_to_sign_in_and_serves_nothing(door):
    reply = door.get("/?deck=1")
    assert reply.status_code == 302
    assert reply.headers["location"] == "/auth/login?return_to=%2F%3Fdeck%3D1"
    assert door.upstream_requests == []


def test_the_pages_files_need_a_session_like_the_page(door):
    for path in ("/client.BEp6_VCi.js", "/styles.css", "/static/client.js"):
        assert door.get(path).status_code == 302, path
        assert door.get(path, headers=_as(ALICE)).status_code == 200, path


def test_a_page_load_with_a_session_serves_the_page_without_the_cookie_reaching_jacs_server(door):
    assert "<title>app</title>" in door.get("/", headers=_as(ALICE)).text
    assert "cookie" not in door.upstream_requests[0].headers


def test_a_data_call_with_no_session_answers_401(door):
    assert door.post("/walker/ListDecks", json={}).status_code == 401
    assert door.post("/function/list_formats", json={}).status_code == 401
    assert door.get("/me").status_code == 401
    assert door.get("/docs").status_code == 401


def test_a_data_call_from_another_origin_answers_403_even_with_a_session(door):
    for origin in ("http://evil.example", "null", "https://knowledge-pool.test.evil.example", None):
        reply = door.post("/walker/ListDecks", json={}, headers=_as(ALICE), origin=origin)
        assert reply.status_code == 403, origin


def test_a_data_call_with_a_session_and_the_apps_origin_runs_as_that_user(door):
    bob = _as(sealed("user_bob", "Bob Example"))
    assert door.post("/walker/CreateDeck", json={"name": "Alice's deck"}, headers=_as(ALICE)).status_code == 200
    mine = door.post("/walker/ListDecks", json={}, headers=_as(ALICE)).json()["data"]["reports"][0]
    theirs = door.post("/walker/ListDecks", json={}, headers=bob).json()["data"]["reports"][0]
    assert [d["name"] for d in mine] == ["Alice's deck"] and theirs == []


def test_a_session_does_not_open_the_connector(door):
    assert door.get("/mcp", headers=_as(ALICE)).status_code == 401


def test_the_sign_in_start_sends_the_browser_to_authkit_with_a_state_and_the_return_address(door):
    reply = door.get("/auth/login?return_to=/decks")
    where = urlparse(reply.headers["location"])
    assert reply.status_code == 302 and f"{where.scheme}://{where.netloc}{where.path}" == LOGIN_URL
    query = parse_qs(where.query)
    assert query["redirect_uri"] == [PUBLIC_ORIGIN + "/auth/callback"] and query["state"][0]


def test_signing_in_sets_a_host_only_http_only_secure_lax_cookie_and_returns_to_the_same_address(door):
    reply = _sign_in(door, "code-alice", return_to="/?deck=1")
    assert (reply.status_code, reply.headers["location"]) == (302, "/?deck=1")
    cookie = _set_cookies(reply)["kp_session"]
    for attribute in ("HttpOnly", "Secure", "SameSite=Lax", "Path=/"):
        assert attribute in cookie.split("; "), attribute
    assert "domain" not in cookie.lower() and cookie.startswith(f"kp_session={ALICE};")
    assert "kp_login=; Max-Age=0" in _set_cookies(reply)["kp_login"]
    assert "<title>app</title>" in door.get("/").text


def test_a_signed_in_user_stays_signed_in_across_requests(door):
    _sign_in(door, "code-alice")
    for _ in range(3):
        assert door.get("/me").json() == {"name": "Alice Example"}


def test_each_sign_in_stores_the_google_display_name_on_the_users_own_root(door):
    _sign_in(door, "code-alice")
    assert door.get("/me").json() == {"name": "Alice Example"}
    _sign_in(door, "code-alice-renamed")
    assert door.get("/me").json() == {"name": "Alice Renamed"}
    assert door.get("/me", headers=_as(sealed("user_bob"))).json() == {"name": "Unknown user"}


def test_a_user_with_no_display_name_is_shown_as_unknown(door):
    _sign_in(door, "code-nameless")
    assert door.get("/me").json() == {"name": "Unknown user"}


def test_a_person_workos_refuses_gets_403_and_no_session(door):
    reply = _sign_in(door, "code-stranger")
    assert reply.status_code == 403 and "kp_session" not in _set_cookies(reply)
    assert door.get("/me").status_code == 401


def test_a_callback_whose_state_is_not_the_one_started_is_refused(door):
    door.get("/auth/login")
    for query in ("code=code-alice&state=forged", "code=code-alice", "state=x"):
        reply = door.get(f"/auth/callback?{query}")
        assert reply.status_code == 400 and "kp_session" not in _set_cookies(reply), query
    assert door.get("/auth/callback?code=code-alice&state=x", headers={"cookie": ""}).status_code == 400


@pytest.mark.parametrize("target", ["https://evil.example/", "//evil.example/", "/\\evil.example", "evil"])
def test_sign_in_never_returns_to_another_site(door, target):
    assert _sign_in(door, "code-alice", return_to=target).headers["location"] == "/"


def test_an_expired_access_token_is_renewed_and_the_cookie_rewritten(door):
    reply = door.get("/me", headers=_as(sealed("user_alice", "Alice Example", old=True)))
    assert reply.status_code == 200
    assert _set_cookies(reply)["kp_session"].startswith(f"kp_session={ALICE};")
    assert "HttpOnly" in _set_cookies(reply)["kp_session"]
    assert "set-cookie" not in door.get("/me", headers=_as(ALICE)).headers


def test_signing_out_ends_the_session_and_clears_the_cookie(door, sessions):
    _sign_in(door, "code-alice")
    reply = door.get("/auth/logout")
    assert reply.status_code == 302
    assert reply.headers["location"] == f"{LOGOUT_URL}?return_to={quote(PUBLIC_ORIGIN + '/', safe='')}"
    assert _set_cookies(reply)["kp_session"].startswith("kp_session=; Max-Age=0")
    assert door.get("/me").status_code == 401
    assert door.get("/me", headers=_as(ALICE)).status_code == 401


def test_a_session_that_ended_mid_page_gets_401_then_the_reload_ends_at_sign_in(door, sessions):
    old = _as(ALICE)
    assert door.post("/walker/ListDecks", json={}, headers=old).status_code == 200
    sessions.ended.add(ALICE)
    assert door.post("/walker/ListDecks", json={}, headers=old).status_code == 401
    reload = door.get("/", headers=old)
    assert reload.status_code == 302 and reload.headers["location"].startswith("/auth/login?")
    assert _set_cookies(reload)["kp_session"].startswith("kp_session=; Max-Age=0")


def test_a_forged_session_is_no_session(door):
    assert door.get("/me", headers=_as("not-sealed")).status_code == 401
    assert door.get("/", headers=_as("not-sealed")).status_code == 302


def test_a_connector_token_still_opens_the_connector_and_runs_as_its_user(door):
    bearer = {"authorization": "Bearer " + door.issuer.token("user_alice")}
    assert door.get("/mcp", headers=bearer).text == "mcp app: /mcp"
    assert door.get("/me", headers=bearer).status_code == 200
    stranger = {"authorization": "Bearer " + TestIssuer().token("user_alice")}
    assert door.get("/mcp", headers=stranger).status_code == 401


def test_the_sign_in_paths_and_health_answer_without_a_session(door):
    assert door.get("/auth/login").status_code == 302
    assert door.get("/auth/logout").status_code == 302
    assert door.get("/healthz").text == "ok"


def test_local_mode_has_no_sign_in_and_no_session_check_needed(tmp_path, sessions):
    with FrontDoorClient(tmp_path, sessions=sessions) as local:
        assert local.get("/auth/login").status_code == 404
        assert local.get("/auth/callback?code=code-alice&state=x").status_code == 404
        assert local.get("/auth/logout").status_code == 404
        assert local.get("/me").json() == {"name": "Unknown user"}
