"""The gatekeeper without Jac's graph: `gatekeeper.guarded` around a stub app that
answers who the request's caller is, with the WorkOS and AuthKit stand-ins
(`tests/hosted_tokens.py`, `tests/hosted_sessions.py`). No database, no front door."""

import pytest
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import PlainTextResponse
from starlette.routing import Route
from starlette.testclient import TestClient

import gatekeeper
import graph_runner
import hosted_auth
import rate_limits
from tests.hosted_sessions import StandInSessions, sealed
from tests.hosted_tokens import AUDIENCE, ISSUER, TestIssuer

ORIGIN = "https://knowledge-pool.test"
LIMIT = 3


class Clock:
    def __call__(self) -> float:
        return 1000.0


def _who(_request: Request) -> PlainTextResponse:
    caller = gatekeeper.current_caller()
    return PlainTextResponse(caller.user_id if caller else "nobody")


def _door(monkeypatch, issuer=None, sessions=None, mode="hosted") -> TestClient:
    monkeypatch.setenv("KP_MODE", mode)
    monkeypatch.setenv(rate_limits.ADDRESS_LIMIT_SETTING, str(LIMIT))
    monkeypatch.setenv(rate_limits.USER_LIMIT_SETTING, str(LIMIT))
    auth = hosted_auth.AuthKitVerifier(issuer=ISSUER, audience=AUDIENCE, key_for=issuer.key_for) if issuer else None
    config = gatekeeper.GatekeeperConfig(
        origins=[ORIGIN], auth=auth, sessions=sessions, public_origin=ORIGIN, limits=rate_limits.rate_limits(Clock())
    )
    inner = Starlette(routes=[Route("/{path:path}", _who, methods=["GET", "POST"])])
    return TestClient(gatekeeper.guarded(inner, config), base_url=ORIGIN, follow_redirects=False)


def test_a_bearer_token_yields_its_subject_as_the_caller(monkeypatch):
    issuer = TestIssuer()
    door = _door(monkeypatch, issuer)
    reply = door.get("/mcp", headers={"authorization": f"Bearer {issuer.token(sub='user_alice')}"})
    assert reply.text == "user_alice"


def test_a_browser_session_yields_its_user_as_the_caller(monkeypatch):
    door = _door(monkeypatch, sessions=StandInSessions())
    door.cookies.set(gatekeeper.SESSION_COOKIE, sealed("user_bob", "Bob Example"), domain="knowledge-pool.test")
    assert door.get("/me-not-a-route").text == "user_bob"


def test_a_request_from_no_one_is_a_401_that_never_reaches_the_app(monkeypatch):
    door = _door(monkeypatch, TestIssuer())
    refused = door.get("/mcp")
    assert refused.status_code == 401 and "resource_metadata" in refused.headers["www-authenticate"]


def test_a_page_load_from_no_one_is_sent_to_sign_in(monkeypatch):
    door = _door(monkeypatch, sessions=StandInSessions())
    reply = door.get("/")
    assert reply.status_code == 302 and reply.headers["location"].startswith(gatekeeper.LOGIN_PATH)


def test_a_caller_past_the_user_limit_gets_a_429(monkeypatch):
    issuer = TestIssuer()
    door = _door(monkeypatch, issuer)
    headers = {"authorization": f"Bearer {issuer.token()}"}
    assert [door.get("/mcp", headers=headers).status_code for _ in range(LIMIT)] == [200] * LIMIT
    assert door.get("/mcp", headers=headers).status_code == 429


def test_local_mode_yields_the_local_user_with_no_sign_in(monkeypatch):
    door = _door(monkeypatch, mode="local")
    assert door.get("/anything").text == graph_runner.LOCAL_USER


def test_hosted_mode_outside_a_request_has_no_caller(monkeypatch):
    monkeypatch.setenv("KP_MODE", "hosted")
    assert gatekeeper.current_caller() is None and gatekeeper.request_caller() is None


def test_an_unknown_mode_is_refused(monkeypatch):
    monkeypatch.setenv("KP_MODE", "public")
    with pytest.raises(ValueError):
        gatekeeper.current_caller()
