"""The quest list through the web page's data calls (Seam B): hosted mode over HTTP
with test-signed tokens. Alice reads her own quest list, marks copies got and exports
it; Bob reads Alice's by handle and cannot change it."""

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


@pytest.fixture
def alice_with_a_deck(client, alice):
    """Alice has a deck of four Lightning Bolts and owns one; the Bolt's oracle id."""
    bolt = client.post("/function/search_cards", json={"query": "Lightning Bolt"}, headers=alice).json()["data"]["result"]["hits"][0]["oracle_id"]
    [deck] = reports(client.post("/walker/CreateDeck", json={"name": "Burn"}, headers=alice))
    reports(client.post(
        "/walker/EditDeck",
        json={"deck_id": deck["_jac_id"], "changes": [{"oracle_id": bolt, "count": 4, "zone": "main", "reason": "web test"}]},
        headers=alice,
    ))
    reports(client.post("/walker/ChangeCollection", json={"oracle_id": bolt, "count": 1, "reason": "web test"}, headers=alice))
    return bolt


def test_a_user_reads_their_quest_list_marks_copies_got_and_exports_it(client, alice, alice_with_a_deck):
    [quest] = reports(client.post("/walker/GetQuestList", json={}, headers=alice))
    assert [(l["oracle_id"], l["count"]) for l in quest["lines"]] == [(alice_with_a_deck, 3)]
    [after] = reports(client.post("/walker/GotQuest", json={"oracle_id": alice_with_a_deck, "count": 2}, headers=alice))
    assert [l["count"] for l in after["lines"]] == [1]
    [exported] = reports(client.post("/walker/GetQuestList", json={"export": True}, headers=alice))
    assert exported["text"].splitlines()[0].startswith("1 ")


def test_a_user_reads_another_users_quest_list_by_handle_and_it_changes_nothing(client, alice, bob, alice_with_a_deck):
    [users] = reports(client.post("/walker/ListUsers", json={}, headers=bob))
    seen = {
        u["handle"]: reports(client.post("/walker/GetOtherQuestList", json={"handle": u["handle"]}, headers=bob))[0]
        for u in users
    }
    [handle] = [h for h, q in seen.items() if q["lines"]]
    assert [(l["oracle_id"], l["count"]) for l in seen[handle]["lines"]] == [(alice_with_a_deck, 3)]
    [mine] = reports(client.post("/walker/GetQuestList", json={}, headers=bob))
    assert mine["lines"] == []
