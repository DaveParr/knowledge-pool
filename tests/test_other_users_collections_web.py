"""Other users' collections through the web page's data calls (Seam B): hosted mode
over HTTP with test-signed tokens. Bob lists the other users, reads Alice's
collection by handle, and cannot change it."""

import pytest

from tests.front_door_client import FrontDoorClient
from tests.hosted_tokens import TestIssuer

pytestmark = pytest.mark.usefixtures("jac_db_url")


@pytest.fixture
def issuer():
    return TestIssuer()


@pytest.fixture
def client(tmp_path, issuer, monkeypatch):
    monkeypatch.setenv("KP_MODE", "hosted")
    with FrontDoorClient(tmp_path, hosted=issuer) as c:
        yield c


@pytest.fixture
def alice(issuer):
    return {"authorization": f"Bearer {issuer.token('user_alice')}"}


@pytest.fixture
def bob(issuer):
    return {"authorization": f"Bearer {issuer.token('user_bob')}"}


def reports(reply) -> list:
    assert reply.status_code == 200, reply.text
    return reply.json()["data"]["reports"]


def test_a_user_lists_the_other_users_by_handle_and_name_and_reads_a_collection_read_only(client, alice, bob):
    hits = client.post("/function/search_cards", json={"query": "Lightning Bolt"}, headers=alice).json()["data"]["result"]["hits"]
    oracle_id = hits[0]["oracle_id"]
    reports(client.post(
        "/walker/ChangeCollection", json={"oracle_id": oracle_id, "count": 3, "reason": "web test"}, headers=alice
    ))
    [users] = reports(client.post("/walker/ListUsers", json={}, headers=bob))
    assert all(set(u) >= {"handle", "name"} for u in users)
    assert all("@" not in u["handle"] and "user_" not in u["handle"] for u in users)
    seen_by_handle = {
        u["handle"]: reports(client.post("/walker/GetOtherCollection", json={"handle": u["handle"]}, headers=bob))[0]
        for u in users
    }
    [handle] = [h for h, c in seen_by_handle.items() if c["total"] == 3]
    assert [(c["oracle_id"], c["count"]) for c in seen_by_handle[handle]["cards"]] == [(oracle_id, 3)]
    [mine] = reports(client.post("/walker/GetCollection", json={}, headers=bob))
    assert mine["cards"] == []
    [refused] = reports(client.post(
        "/walker/ChangeCollection",
        json={"oracle_id": oracle_id, "count": 1, "reason": "sneaky", "handle": handle},
        headers=bob,
    ))
    assert refused["code"] == "not-your-collection"
    [after] = reports(client.post("/walker/GetOtherCollection", json={"handle": handle}, headers=bob))
    assert after["total"] == 3
    [alices_list] = reports(client.post("/walker/ListUsers", json={}, headers=alice))
    assert handle not in [u["handle"] for u in alices_list]
