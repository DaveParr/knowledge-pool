"""Other users' decks through the web page's data calls (Seam B): hosted mode over
HTTP with test-signed tokens. Bob browses Alice's decks, opens one and copies it;
a change to it is refused with `not-your-deck`."""

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


def alices_deck(client, alice) -> str:
    made = reports(client.post("/walker/CreateDeck", json={"name": "Alice's Burn"}, headers=alice))
    return made[0]["_jac_id"]


def test_other_users_decks_list_owner_name_and_format_and_never_your_own(client, alice, bob):
    deck_id = alices_deck(client, alice)
    client.post("/walker/CreateDeck", json={"name": "Bob's Own"}, headers=bob)
    [others] = reports(client.post("/walker/ListOtherDecks", json={}, headers=bob))
    assert [(d["id"], d["name"], d["format"], d["owner"]) for d in others] == [
        (deck_id, "Alice's Burn", "standard", "Unknown user")
    ]
    [alices_view] = reports(client.post("/walker/ListOtherDecks", json={}, headers=alice))
    assert [d["name"] for d in alices_view] == ["Bob's Own"]


def test_opening_another_users_deck_shows_all_of_it_with_its_history(client, alice, bob):
    deck_id = alices_deck(client, alice)
    [view] = reports(client.post("/walker/GetDeck", json={"deck_id": deck_id}, headers=bob))
    assert view["name"] == "Alice's Burn" and "history" in view


def test_copying_makes_my_own_deck_and_leaves_the_original(client, alice, bob):
    deck_id = alices_deck(client, alice)
    [copy] = reports(client.post("/walker/CopyOtherDeck", json={"deck_id": deck_id}, headers=bob))
    assert copy["name"] == "Alice's Burn (copy)"
    mine = reports(client.post("/walker/ListDecks", json={}, headers=bob))[0]
    assert [d["name"] for d in mine] == ["Alice's Burn (copy)"]
    assert [d["name"] for d in reports(client.post("/walker/ListDecks", json={}, headers=alice))[0]] == ["Alice's Burn"]


def test_copying_an_id_that_names_no_deck_is_no_such_deck(client, bob):
    [error] = reports(client.post("/walker/CopyOtherDeck", json={"deck_id": "nope"}, headers=bob))
    assert error["code"] == "no-such-deck"


def test_changing_another_users_deck_is_refused_with_the_not_your_deck_message(client, alice, bob):
    deck_id = alices_deck(client, alice)
    [error] = reports(client.post("/walker/SetDeckFormat", json={"deck_id": deck_id, "format": "modern"}, headers=bob))
    assert error["code"] == "not-your-deck" and "Copy it" in error["message"]
