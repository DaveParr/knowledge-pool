"""Hosted mode's token check (Seam B): the front door over HTTP, with tokens
signed by a test key against a test issuer and audience. The caller of a call
is the token's `sub`, and a call without a valid token is refused."""

import pytest

import hosted_auth
from tests.front_door_client import FrontDoorClient
from tests.hosted_tokens import AUDIENCE, ISSUER, TestIssuer, new_key

pytestmark = pytest.mark.usefixtures("jac_db_url")

SETTINGS = {
    "KP_AUTHKIT_DOMAIN": ISSUER,
    "KP_PUBLIC_MCP_URL": AUDIENCE,
    "WORKOS_CLIENT_ID": "client_test",
    "WORKOS_API_KEY": "sk_test_key",
    "WORKOS_COOKIE_PASSWORD": "x" * 32,
}


@pytest.fixture
def issuer():
    return TestIssuer()


@pytest.fixture
def client(tmp_path, issuer, monkeypatch):
    monkeypatch.setenv("KP_MODE", "hosted")
    with FrontDoorClient(tmp_path, hosted=issuer) as c:
        yield c


def bearer(token: str) -> dict:
    return {"authorization": f"Bearer {token}"}


def test_a_good_token_runs_the_call_as_its_sub(client, issuer):
    alice = bearer(issuer.token("user_alice"))
    bob = bearer(issuer.token("user_bob"))
    assert client.post("/walker/CreateDeck", json={"name": "Alice's deck"}, headers=alice).status_code == 200
    [alices] = client.post("/walker/ListDecks", json={}, headers=alice).json()["data"]["reports"][0]
    assert alices["name"] == "Alice's deck"
    assert client.post("/walker/ListDecks", json={}, headers=bob).json()["data"]["reports"][0] == []


def test_a_good_token_reaches_mcp(client, issuer):
    reply = client.get("/mcp", headers=bearer(issuer.token()))
    assert reply.text == "mcp app: /mcp"


@pytest.mark.parametrize("path", ["/mcp", "/walker/ListDecks", "/function/list_formats", "/", "/static/client.js", "/me"])
def test_no_token_answers_401(client, path):
    reply = client.post(path, json={}) if path.startswith(("/walker", "/function")) else client.get(path)
    assert reply.status_code == 401
    assert reply.headers["www-authenticate"].startswith("Bearer resource_metadata=")
    assert client.upstream_requests == []


@pytest.mark.parametrize("why", ["audience", "issuer", "expired", "key", "no sub", "not a token"])
def test_a_bad_token_answers_401_on_rest_and_mcp(client, issuer, why):
    token = {
        "audience": lambda: issuer.token(aud="https://knowledge-pool.test/other"),
        "issuer": lambda: issuer.token(iss="https://evil.example"),
        "expired": lambda: issuer.token(expires_in=-60),
        "key": lambda: issuer.token(key=new_key()),
        "no sub": lambda: issuer.token(sub=None),
        "not a token": lambda: "abc.def.ghi",
    }[why]()
    for reply in (
        client.get("/mcp", headers=bearer(token)),
        client.post("/walker/ListDecks", json={}, headers=bearer(token)),
    ):
        assert reply.status_code == 401
    assert client.get("/mcp", headers={"authorization": f"Basic {token}"}).status_code == 401


def test_discovery_and_health_answer_without_a_token(client):
    for path in ("/.well-known/oauth-protected-resource", "/.well-known/oauth-protected-resource/mcp"):
        reply = client.get(path)
        assert reply.status_code == 200
        assert reply.json()["resource"] == AUDIENCE
        assert reply.json()["authorization_servers"] == [ISSUER]
    assert client.get("/healthz").text == "ok"


def test_other_well_known_paths_need_a_token(client):
    assert client.get("/.well-known/openid-configuration").status_code == 401


@pytest.mark.parametrize("missing", sorted(SETTINGS))
def test_hosted_refuses_to_start_without_any_of_its_settings(monkeypatch, missing):
    for name, value in SETTINGS.items():
        monkeypatch.setenv(name, value)
    monkeypatch.delenv(missing)
    with pytest.raises(hosted_auth.HostedSettingsMissing, match=missing):
        hosted_auth.hosted_settings()


def test_a_blank_setting_counts_as_missing(monkeypatch):
    for name, value in SETTINGS.items():
        monkeypatch.setenv(name, value)
    monkeypatch.setenv("WORKOS_API_KEY", "  ")
    with pytest.raises(hosted_auth.HostedSettingsMissing, match="WORKOS_API_KEY"):
        hosted_auth.hosted_settings()


def test_the_settings_name_the_issuer_and_the_audience(monkeypatch):
    for name, value in SETTINGS.items():
        monkeypatch.setenv(name, value)
    monkeypatch.setenv("KP_AUTHKIT_DOMAIN", "auth.knowledge-pool.test")
    settings = hosted_auth.hosted_settings()
    assert settings.issuer == ISSUER and settings.audience == AUDIENCE


def _rpc(client, headers, method, params=None, id=None):
    body = {"jsonrpc": "2.0", "method": method, "params": params or {}}
    if id is not None:
        body["id"] = id
    reply = client.post("/mcp", json=body, origin=None,
                        headers={"accept": "application/json, text/event-stream", **headers})
    assert reply.status_code in (200, 202), reply.text
    return reply


def _session(client, token):
    """Open an MCP session as `token`'s user; the headers every later request carries."""
    headers = bearer(token)
    opened = _rpc(client, headers, "initialize", id=0, params={
        "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "0"}})
    headers["mcp-session-id"] = opened.headers["mcp-session-id"]
    _rpc(client, headers, "notifications/initialized")
    return headers


def _tool(client, headers, name, arguments):
    """Call an MCP tool over HTTP and return its structured result."""
    reply = _rpc(client, headers, "tools/call", {"name": name, "arguments": arguments}, id=2)
    return reply.json()["result"]["structuredContent"]


def test_an_mcp_tool_runs_as_the_token_of_its_own_request(tmp_path, issuer, monkeypatch):
    """The real MCP app: two users' tool calls each see only their own decks."""
    import mcp_server
    from mcp.server.transport_security import TransportSecuritySettings

    monkeypatch.setenv("KP_MODE", "hosted")
    mcp_app = mcp_server.server.streamable_http_app(
        json_response=True, transport_security=TransportSecuritySettings(enable_dns_rebinding_protection=False))
    with FrontDoorClient(tmp_path, hosted=issuer, mcp_app=mcp_app) as client:
        alice = _session(client, issuer.token("user_alice"))
        bob = _session(client, issuer.token("user_bob"))
        _tool(client, alice, "deck_create", {"name": "Alice's deck", "format": "standard"})
        assert [d["name"] for d in _tool(client, alice, "deck_list", {})["result"]] == ["Alice's deck"]
        assert _tool(client, bob, "deck_list", {})["result"] == []


def test_workos_sessions_send_the_browser_to_authkit_and_name_the_user_by_id_and_google_name():
    from browser_session import WorkOSSessions, session_user
    from tests.hosted_settings import HOSTED_SETTINGS

    sessions = WorkOSSessions(
        client_id=HOSTED_SETTINGS["WORKOS_CLIENT_ID"], api_key=HOSTED_SETTINGS["WORKOS_API_KEY"],
        cookie_password=HOSTED_SETTINGS["WORKOS_COOKIE_PASSWORD"],
    )
    url = sessions.login_url("a-state", "https://knowledge-pool.example/auth/callback")
    assert "state=a-state" in url and "provider=authkit" in url and "client_id=client_stand_in" in url
    assert "redirect_uri=https%3A%2F%2Fknowledge-pool.example%2Fauth%2Fcallback" in url
    who = session_user({"id": "user_01", "email": "a@example.com", "first_name": "Ada", "last_name": "Lovelace"})
    assert (who.sub, who.name) == ("user_01", "Ada Lovelace")
    assert session_user({"id": "user_02", "first_name": None}).name == ""
    assert session_user({"first_name": "No Id"}) is None
