"""Walker-free tests for the mtgdeck/1 zone and entry metadata additions."""

import from decks { Holds, DECK_ZONES, CreateDeck, set_card_entry, deck_view }
import from cards { Card, catalog_node }

test "Holds defaults carry no roles, tags, lock or reason" {
    h = Holds();
    assert h.roles == [];
    assert h.tags == [];
    assert h.locked == False;
    assert h.reason == "";
}

test "DECK_ZONES covers all five mtgdeck/1 zones" {
    assert DECK_ZONES == ["commander", "companion", "main", "sideboard", "maybeboard"];
}

test "deck_view does not crash on a commander-zone holding" {
    created = root spawn CreateDeck(name="Commander zone test deck");
    deck = created.reports[0];
    oid = "decks-io-test-fixture-card";
    cat = catalog_node(root);
    if not [cat-->[?:Card, oracle_id == oid]] {
        cat ++> Card(oracle_id=oid, name="Fixture Commander");
    }
    set_card_entry(deck, oid, "commander", 1, roles=["commander"]);
    view = deck_view(deck);
    commander_lines = [c for c in view.cards if c.zone == "commander"];
    assert len(commander_lines) == 1;
    assert commander_lines[0].roles == ["commander"];
}

test "set_card_entry refuses an unknown zone and writes nothing" {
    created = root spawn CreateDeck(name="Bad zone guard test deck");
    deck = created.reports[0];
    oid = "decks-io-test-fixture-card";
    cat = catalog_node(root);
    if not [cat-->[?:Card, oracle_id == oid]] {
        cat ++> Card(oracle_id=oid, name="Fixture Commander");
    }
    assert set_card_entry(deck, oid, "bogus_zone", 1) is None;
    assert deck_view(deck).cards == [];
}
