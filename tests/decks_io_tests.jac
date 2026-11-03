"""Walker-free tests for the mtgdeck/1 zone and entry metadata additions."""

import from decks { Holds, DECK_ZONES, CreateDeck, set_card_entry, deck_view }
import from cards { Card, catalog_node }

test "Holds defaults carry no role, tags, lock or reason" {
    h = Holds();
    assert h.role == "";
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
    set_card_entry(deck, oid, "commander", 1, role="commander");
    view = deck_view(deck);
    commander_lines = [c for c in view.cards if c.zone == "commander"];
    assert len(commander_lines) == 1;
    assert commander_lines[0].role == "commander";
}
