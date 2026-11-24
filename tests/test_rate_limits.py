"""Rate limits at the front door (Seam B): hosted mode over HTTP with test-signed
tokens, a fake clock and low limits. 30 a minute per address for requests with
no valid token, 300 a minute per user for requests with one."""

import logging

import pytest

import gatekeeper
import rate_limits
from tests.front_door_client import FrontDoorClient
from tests.hosted_tokens import TestIssuer

pytestmark = pytest.mark.usefixtures("jac_db_url")

ADDRESS_LIMIT = 3
USER_LIMIT = 5


class Clock:
    def __init__(self):
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


@pytest.fixture
def clock():
    return Clock()


@pytest.fixture
def issuer():
    return TestIssuer()


@pytest.fixture
def client(tmp_path, issuer, clock, monkeypatch):
    monkeypatch.setenv("KP_MODE", "hosted")
    monkeypatch.setenv(rate_limits.ADDRESS_LIMIT_SETTING, str(ADDRESS_LIMIT))
    monkeypatch.setenv(rate_limits.USER_LIMIT_SETTING, str(USER_LIMIT))
    with FrontDoorClient(tmp_path, hosted=issuer, limits=rate_limits.rate_limits(clock)) as c:
        yield c


def bearer(token: str) -> dict:
    return {"authorization": f"Bearer {token}"}


def from_address(address: str, **headers) -> dict:
    return {"x-real-ip": address, **headers}


def test_limits_default_to_the_named_defaults(monkeypatch):
    monkeypatch.delenv(rate_limits.ADDRESS_LIMIT_SETTING, raising=False)
    monkeypatch.delenv(rate_limits.USER_LIMIT_SETTING, raising=False)
    limits = rate_limits.rate_limits()
    assert (limits.addresses.per_minute, limits.users.per_minute) == (
        rate_limits.DEFAULT_ADDRESS_LIMIT, rate_limits.DEFAULT_USER_LIMIT
    )


def test_limits_come_from_variables(monkeypatch):
    monkeypatch.setenv(rate_limits.ADDRESS_LIMIT_SETTING, "7")
    monkeypatch.setenv(rate_limits.USER_LIMIT_SETTING, "9")
    limits = rate_limits.rate_limits()
    assert (limits.addresses.per_minute, limits.users.per_minute) == (7, 9)


def test_requests_without_a_token_are_refused_after_the_address_burst_with_429(client):
    for _ in range(ADDRESS_LIMIT):
        assert client.get("/mcp", headers=from_address("203.0.113.9")).status_code == 401
    refused = client.get("/mcp", headers=from_address("203.0.113.9"))
    assert refused.status_code == 429
    assert refused.headers["retry-after"] == "20"
    assert refused.headers["content-type"].startswith("text/plain")
    assert refused.text == "Too many requests, try again in 20 seconds"
    assert client.upstream_requests == []


def test_another_address_has_its_own_count(client):
    for _ in range(ADDRESS_LIMIT + 1):
        client.get("/mcp", headers=from_address("203.0.113.9"))
    assert client.get("/mcp", headers=from_address("203.0.113.10")).status_code == 401


def test_an_address_bucket_refills_across_the_minute(client, clock):
    for _ in range(ADDRESS_LIMIT + 1):
        client.get("/", headers=from_address("203.0.113.9"))
    clock.now += 19
    assert client.get("/", headers=from_address("203.0.113.9")).status_code == 429
    clock.now += 2
    assert client.get("/", headers=from_address("203.0.113.9")).status_code == 401


def test_the_address_limit_counts_discovery_too(client):
    codes = [client.get("/.well-known/oauth-protected-resource", headers=from_address("203.0.113.9")).status_code
             for _ in range(ADDRESS_LIMIT + 1)]
    assert codes == [200] * ADDRESS_LIMIT + [429]


def test_requests_with_a_valid_token_do_not_count_against_the_address(client, issuer):
    token = bearer(issuer.token("user_alice"))
    for _ in range(ADDRESS_LIMIT + 2):
        assert client.get("/mcp", headers=from_address("203.0.113.9", **token)).status_code == 200
    assert client.get("/mcp", headers=from_address("203.0.113.9")).status_code == 401


def test_a_bad_token_counts_against_the_address(client, issuer):
    stranger = bearer(issuer.token("user_x", aud="https://elsewhere.test"))
    codes = [client.get("/mcp", headers=from_address("203.0.113.9", **stranger)).status_code
             for _ in range(ADDRESS_LIMIT + 1)]
    assert codes == [401] * ADDRESS_LIMIT + [429]


def test_a_user_is_refused_after_the_user_burst_across_connector_and_page_files(client, issuer):
    alice = bearer(issuer.token("user_alice"))
    paths = ["/mcp", "/", "/static/client.js", "/styles.css", "/mcp"]
    assert [client.get(p, headers=alice).status_code for p in paths] == [200] * USER_LIMIT
    refused = client.get("/mcp", headers=alice)
    assert refused.status_code == 429
    assert refused.headers["retry-after"] == "12"
    assert refused.text == "Too many requests, try again in 12 seconds"


def test_one_users_runaway_does_not_limit_another(client, issuer):
    alice = bearer(issuer.token("user_alice"))
    for _ in range(USER_LIMIT + 3):
        client.get("/mcp", headers=alice)
    assert client.get("/mcp", headers=bearer(issuer.token("user_bob"))).status_code == 200


def test_walker_calls_count_against_the_user_too(client, issuer):
    alice = bearer(issuer.token("user_alice"))
    codes = [client.post("/walker/ListDecks", json={}, headers=alice).status_code for _ in range(USER_LIMIT + 1)]
    assert codes == [200] * USER_LIMIT + [429]


def test_the_health_path_is_never_limited(client):
    for _ in range(ADDRESS_LIMIT + USER_LIMIT + 5):
        assert client.get("/healthz", headers=from_address("203.0.113.9")).status_code == 200
    assert client.get("/mcp", headers=from_address("203.0.113.9")).status_code == 401


def test_requests_without_an_address_share_one_unknown_bucket(client):
    codes = [client.get("/mcp").status_code for _ in range(ADDRESS_LIMIT + 1)]
    assert codes == [401] * ADDRESS_LIMIT + [429]
    assert client.get("/mcp", headers=from_address(rate_limits.UNKNOWN_ADDRESS)).status_code == 429


def test_addresses_past_the_table_size_share_unknown(monkeypatch, clock):
    monkeypatch.setattr(rate_limits, "MAX_ADDRESSES", 3)
    limits = rate_limits.rate_limits(clock)
    for n in range(2):
        assert limits.addresses.take(f"10.0.0.{n}") == 0
    # The table is full of addresses that are not yet refilled: a newcomer shares "unknown".
    for _ in range(limits.addresses.per_minute):
        assert limits.addresses.take("10.0.0.99") == 0
    assert limits.addresses.take("10.0.0.99") > 0
    assert limits.addresses.take("10.0.0.100") > 0
    assert len(limits.addresses.tokens) <= 3


def test_a_refused_address_is_logged_once_a_minute(client, clock, caplog):
    caplog.set_level(logging.WARNING, logger="knowledge_pool.rate_limits")
    for _ in range(ADDRESS_LIMIT + 5):
        client.get("/mcp", headers=from_address("203.0.113.9"))
    assert [r.getMessage() for r in caplog.records].count("Rate limit hit for address 203.0.113.9 (3 a minute).") == 1
    clock.now += 61
    for _ in range(ADDRESS_LIMIT + 5):
        client.get("/mcp", headers=from_address("203.0.113.9"))
    assert len([r for r in caplog.records if "203.0.113.9" in r.getMessage()]) == 2


def test_a_refused_user_is_logged_once_a_minute(client, issuer, caplog):
    caplog.set_level(logging.WARNING, logger="knowledge_pool.rate_limits")
    alice = bearer(issuer.token("user_alice"))
    for _ in range(USER_LIMIT + 5):
        client.get("/mcp", headers=alice)
    assert [r.getMessage() for r in caplog.records] == ["Rate limit hit for user user_alice (5 a minute)."]


def test_the_refusal_log_forgets_keys_after_a_minute(clock, monkeypatch):
    monkeypatch.setattr(rate_limits, "LOG_PRUNE_AT", 3)
    buckets = rate_limits.rate_limits(clock).users
    for n in range(3):
        for _ in range(buckets.per_minute + 1):
            buckets.take(f"user_{n}")
    assert len(buckets.logged) == 3
    clock.now += 61
    for _ in range(buckets.per_minute + 1):
        buckets.take("user_late")
    assert list(buckets.logged) == ["user_late"]


def test_the_sign_in_paths_count_against_the_address(client):
    codes = [client.get(gatekeeper.LOGIN_PATH, headers=from_address("203.0.113.9")).status_code
             for _ in range(ADDRESS_LIMIT + 1)]
    assert codes[-1] == 429 and 429 not in codes[:-1]
