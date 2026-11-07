"""Walker tests for creating and listing decks."""

import from decks { Deck, Holds, CreateDeck, ListDecks, mana_curve }
import from cards { Card }

test "create deck reports a deck with a trimmed name" {
    result = root spawn CreateDeck(name="  Mono Red  ");
    deck = result.reports[0];
    assert deck.name == "Mono Red";
    assert deck.created_at != "";
}

test "list decks includes a new deck" {
    root spawn CreateDeck(name="Listed deck");
    result = root spawn ListDecks();
    names = [d.name for d in result.reports[0]];
    assert "Listed deck" in names;
}

test "blank deck name creates nothing" {
    before = len([root-->[?:Deck]]);
    result = root spawn CreateDeck(name="   ");
    assert len(result.reports) == 0;
    assert len([root-->[?:Deck]]) == before;
}

"""Attach `count` copies of `card` to `deck` in `zone`."""
def _hold(deck: Deck, card: Card, count: int, zone: str) {
    deck +>:Holds(count=count, zone=zone):+> card;
}

test "mana curve buckets non-land main cards by mana value, weighted by count" {
    result = root spawn CreateDeck(name="Curve test");
    deck = result.reports[0];

    bolt = Card(oracle_id="bolt", name="Lightning Bolt", mana_value=1.0, types=["Instant"]);
    big_spell = Card(oracle_id="big", name="Big Spell", mana_value=9.0, types=["Sorcery"]);
    mountain = Card(oracle_id="mtn", name="Mountain", mana_value=0.0, types=["Land"]);
    valakut = Card(
        oracle_id="val", name="Valakut Awakening // Valakut Stoneforge", mana_value=3.0,
        types=["Sorcery", "Land"]
    );
    fireball = Card(oracle_id="fb", name="Fireball", mana_value=0.0, types=["Sorcery"]);

    _hold(deck, bolt, 4, "main");
    _hold(deck, big_spell, 1, "main");
    _hold(deck, mountain, 20, "main");
    _hold(deck, valakut, 1, "main");
    _hold(deck, fireball, 1, "main");
    _hold(deck, bolt, 2, "sideboard");

    curve = mana_curve(deck);

    assert curve.buckets == {
        "0": 1, "1": 4, "2": 0, "3": 1, "4": 0, "5": 0, "6": 0, "7+": 1
    };
    assert curve.average_mv == 2.29;
}

test "mana curve is all zero for a deck with no non-land main cards" {
    result = root spawn CreateDeck(name="Empty curve test");
    deck = result.reports[0];
    mountain = Card(oracle_id="mtn2", name="Mountain", mana_value=0.0, types=["Land"]);
    _hold(deck, mountain, 40, "main");

    curve = mana_curve(deck);

    assert curve.buckets == {
        "0": 0, "1": 0, "2": 0, "3": 0, "4": 0, "5": 0, "6": 0, "7+": 0
    };
    assert curve.average_mv == 0.0;
}
