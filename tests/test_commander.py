"""Commander rules against known decks (including real MTGJSON precons), through the walkers."""

import json
from pathlib import Path

import pytest
from jaclang.runtimelib.testing import JacTestClient

FIXTURES = Path(__file__).parent / "fixtures"
DECKS = json.loads((FIXTURES / "commander_decks.json").read_text())


def _reports(resp):
    body = resp.json()
    assert body["ok"], body
    return body["data"]["reports"]


@pytest.fixture
def client(tmp_path):
    c = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    yield c
    c.close()


def _deck_text(deck: dict) -> str:
    """A text-format list with Commander, Companion, Deck and Sideboard headers."""
    if "precon" in deck:
        data = json.loads((FIXTURES / "mtgjson_decks" / f"{deck['precon']}.json").read_text())["data"]
        # A precon lists a card once per printing, so add counts up by name.
        def counts(cards):
            out: dict[str, int] = {}
            for c in cards:
                out[c["name"]] = out.get(c["name"], 0) + c["count"]
            return out

        zones = {"Commander": counts(data["commander"]), "Deck": counts(data["mainBoard"])}
    else:
        zones = {
            "Commander": deck["commander"],
            "Companion": deck["companion"],
            "Deck": deck["main"],
            "Sideboard": deck["sideboard"],
        }
    blocks = []
    for header, cards in zones.items():
        if cards:
            blocks.append("\n".join([header, *(f"{n} {name}" for name, n in cards.items())]))
    return "\n\n".join(blocks) + "\n"


def _build(client, deck) -> dict:
    [made] = _reports(
        client.post(
            "/walker/CreateDeckFromList",
            json={"name": deck["name"], "format": "text", "text": _deck_text(deck), "play_format": "commander"},
        )
    )
    assert made["unresolved"] == [], made["unresolved"]
    return _reports(client.post("/walker/GetDeck", json={"deck_id": made["deck_id"]}))[0]


def test_the_set_has_at_least_10_decks_of_each_kind_and_a_precon():
    assert len(DECKS) >= 10
    assert any(d["legal"] for d in DECKS) and any(not d["legal"] for d in DECKS)
    assert any("precon" in d for d in DECKS)


@pytest.mark.parametrize("deck", DECKS, ids=[d["name"] for d in DECKS])
def test_validator_agrees_with_known_commander_decks(client, deck):
    view = _build(client, deck)
    assert view["format"] == "commander"
    assert view["legal"] == deck["legal"], view["violations"]
    assert sorted({v["rule"] for v in view["violations"]}) == deck["rules"]



PRECON_TIMEY_WIMEY = next(d for d in DECKS if d["name"] == "Precon: Timey-Wimey")


def test_game_changers_on_commander_decks(client):
    view = _build(client, PRECON_TIMEY_WIMEY)
    assert view["game_changers"] == {**view["game_changers"], "cards": ["Farewell"], "count": 1, "bracket_hint": "Bracket 3"}


def test_four_game_changers_hint_bracket_4(client):
    names = ["Rhystic Study", "Demonic Tutor", "Smothering Tithe", "Mana Vault"]
    deck = {
        "name": "Four changers",
        "commander": {"Kenrith, the Returned King": 1},
        "companion": {},
        "main": {**{n: 1 for n in names}, "Plains": 95},
        "sideboard": {},
    }
    view = _build(client, deck)
    assert view["game_changers"]["count"] == 4
    assert view["game_changers"]["bracket_hint"] == "Bracket 4+"


def test_game_changers_only_on_commander_decks(client):
    view = _build(client, PRECON_TIMEY_WIMEY)
    assert view["game_changers"] is not None
    deck_id = view["id"]
    client.post("/walker/SetDeckFormat", json={"deck_id": deck_id, "format": "modern"})
    assert _reports(client.post("/walker/GetDeck", json={"deck_id": deck_id}))[0]["game_changers"] is None
    client.post("/walker/SetDeckFormat", json={"deck_id": deck_id, "format": "commander"})
    assert _reports(client.post("/walker/GetDeck", json={"deck_id": deck_id}))[0]["game_changers"] is not None
