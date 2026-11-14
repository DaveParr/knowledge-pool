"""Deck legality (DeckView `legal`/`violations`) against a set of known legal and illegal 60-card decks.

Card legalities come from the fixture (real MTGJSON data, 2 Nov 2026), so the
expected results stay fixed when bans change.
"""

import json
from pathlib import Path

import pytest
from jaclang.testing.testing import JacTestClient

from catalog import store

DECKS = json.loads((Path(__file__).parent / "fixtures" / "legality_decks.json").read_text())


def _reports(resp):
    body = resp.json()
    assert body["ok"], body
    return body["data"]["reports"]


def _oracle_id(name: str) -> str:
    return next(c["oracle_id"] for c in store.search(name) if c["name"] == name)


@pytest.fixture
def client(tmp_path):
    c = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    yield c
    c.close()


def _build(client, deck) -> dict:
    _reports(client.post("/walker/CreateDeck", json={"name": deck["name"], "format": deck["format"]}))
    deck_id = _reports(client.post("/walker/ListDecks"))[0][-1]["_jac_id"]
    view = _reports(client.post("/walker/GetDeck", json={"deck_id": deck_id}))[0]
    for zone in ("main", "sideboard"):
        for name, count in deck[zone].items():
            view = _reports(
                client.post(
                    "/walker/SetCardCount",
                    json={"deck_id": deck_id, "oracle_id": _oracle_id(name), "count": count, "zone": zone},
                )
            )[0]
    return view


def test_the_set_has_at_least_20_decks_of_each_kind():
    assert len(DECKS) >= 20
    assert any(d["legal"] for d in DECKS) and any(not d["legal"] for d in DECKS)


@pytest.mark.parametrize("deck", DECKS, ids=[d["name"] for d in DECKS])
def test_validator_agrees_with_known_decks(client, deck):
    view = _build(client, deck)
    assert view["format"] == deck["format"]
    assert view["legal"] == deck["legal"], view["violations"]
    assert sorted({v["rule"] for v in view["violations"]}) == deck["rules"]
    for v in view["violations"]:
        assert v["message"]


def test_violation_names_the_card_and_rule(client):
    view = _build(client, {"name": "x", "format": "standard", "main": {"Shock": 5, "Mountain": 55}, "sideboard": {}})
    assert view["violations"] == [
        {**view["violations"][0], "rule": "copy-limit", "card": "Shock", "message": "5 copies of Shock; Standard allows 4."}
    ]


def test_changing_format_revalidates(client):
    deck = {"name": "Bolts", "format": "standard", "main": {"Lightning Bolt": 4, "Mountain": 56}, "sideboard": {}}
    view = _build(client, deck)
    assert not view["legal"]
    view = _reports(client.post("/walker/SetDeckFormat", json={"deck_id": view["id"], "format": "modern"}))[0]
    assert view["legal"] and view["format"] == "modern"
    [err] = _reports(client.post("/walker/SetDeckFormat", json={"deck_id": view["id"], "format": "vintage"}))
    assert err["code"] == "unknown-format"
    assert err["message"].startswith("Unknown format vintage. Use one of: standard")


def test_legality_is_not_stored_on_the_deck_or_cards(client):
    view = _build(client, {"name": "x", "format": "standard", "main": {"Mountain": 60}, "sideboard": {}})
    deck = next(d for d in _reports(client.post("/walker/ListDecks"))[0] if d["_jac_id"] == view["id"])
    assert set(deck) - {"_jac_type", "_jac_type_id", "_jac_id", "_jac_archetype"} == {"name", "created_at", "format", "history"}
