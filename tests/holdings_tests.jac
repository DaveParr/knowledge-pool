"""Tests for Deck holdings: change_holding and replace_holdings, the one way
a deck's cards change."""

import from decks {
    Deck, Holds, ZONES, HoldingEntry, CreateDeck, change_holding, replace_holdings, holdings, deck_view
}
import from cards { Card, catalog_node }

"""A fresh deck with its own name."""
def _deck(name: str) -> Deck {
    created = root spawn CreateDeck(name=name);
    return created.reports[0] as Deck;
}

"""Make sure a catalogue Card node exists for `oid`, and return the oid."""
def _card(oid: str, name: str) -> str {
    cat = catalog_node(root);
    if not [cat-->[?:Card, oracle_id == oid]] {
        cat ++> Card(oracle_id=oid, name=name);
    }
    return oid;
}

"""(oracle_id, zone) -> count for everything the deck holds."""
def _held(deck: Deck) -> dict[tuple[str, str], int] {
    return {(c.oracle_id, e.zone): e.count for (e, c) in holdings(deck)};
}

test "Holds defaults carry no roles, tags, lock or reason" {
    h = Holds();
    assert h.roles == [];
    assert h.tags == [];
    assert h.locked == False;
    assert h.reason == "";
}

test "ZONES is the one list of all five mtgdeck/1 zones" {
    assert ZONES == ["commander", "companion", "main", "sideboard", "maybeboard"];
}

test "change_holding sets, adds on top, and removes at zero" {
    deck = _deck("Holdings set/add test");
    bolt = _card("holdings-test-bolt", "Test Bolt");
    assert change_holding(deck, bolt, "main", 4, "seed") == "";
    assert change_holding(deck, bolt, "main", 2, "more", add=True) == "";
    assert _held(deck) == {(bolt, "main"): 6};
    assert change_holding(deck, bolt, "main", 1, "trim") == "";
    assert _held(deck) == {(bolt, "main"): 1};
    assert change_holding(deck, bolt, "main", 0, "cut") == "";
    assert _held(deck) == {};
}

test "change_holding logs each change with its reason and before/after" {
    deck = _deck("Holdings history test");
    bolt = _card("holdings-test-bolt", "Test Bolt");
    change_holding(deck, bolt, "sideboard", 3, "sideboard plan");
    change_holding(deck, bolt, "sideboard", 1, "one more", add=True);
    notes = [(n.name, n.zone, n.before, n.after, n.reason) for n in deck.history];
    assert notes == [
        ("Test Bolt", "sideboard", 0, 3, "sideboard plan"),
        ("Test Bolt", "sideboard", 3, 4, "one more")
    ];
}

test "a change that leaves the count as it was is applied but not logged" {
    deck = _deck("Holdings no-op test");
    bolt = _card("holdings-test-bolt", "Test Bolt");
    assert change_holding(deck, bolt, "main", 0, "nothing there") == "";
    change_holding(deck, bolt, "main", 2, "seed");
    assert change_holding(deck, bolt, "main", 2, "same again") == "";
    assert [n.reason for n in deck.history] == ["seed"];
}

test "change_holding refuses bad input and writes nothing" {
    deck = _deck("Holdings refusal test");
    bolt = _card("holdings-test-bolt", "Test Bolt");
    assert change_holding(deck, bolt, "bogus_zone", 1, "why") != "";
    assert change_holding(deck, bolt, "main", -1, "why") != "";
    assert change_holding(deck, bolt, "main", 0, "why", add=True) != "";
    assert change_holding(deck, bolt, "main", True, "why") != "";
    assert change_holding(deck, bolt, "main", 1, "   ") != "";
    assert change_holding(deck, "not-a-card", "main", 1, "why") != "";
    assert _held(deck) == {};
    assert deck.history == [];
}

test "change_holding accepts every zone, including commander" {
    deck = _deck("Holdings commander test");
    cmdr = _card("holdings-test-commander", "Test Commander");
    assert change_holding(deck, cmdr, "commander", 1, "the general") == "";
    lines = [c for c in deck_view(deck).cards if c.zone == "commander"];
    assert len(lines) == 1;
}

test "change_holding keeps an entry's roles, tags, lock and reason" {
    deck = _deck("Holdings metadata kept test");
    bolt = _card("holdings-test-bolt", "Test Bolt");
    replace_holdings(
        deck,
        [HoldingEntry(oracle_id=bolt, zone="main", count=4, roles=["removal"], tags=["burn"], locked=True, reason="cheap")],
        "import"
    );
    change_holding(deck, bolt, "main", 3, "trim");
    line = deck_view(deck).cards[0];
    assert (line.count, line.roles, line.tags, line.locked, line.reason) == (3, ["removal"], ["burn"], True, "cheap");
}

test "replace_holdings makes the deck hold exactly the entries, logging each count change" {
    deck = _deck("Holdings replace test");
    bolt = _card("holdings-test-bolt", "Test Bolt");
    cmdr = _card("holdings-test-commander", "Test Commander");
    change_holding(deck, bolt, "main", 4, "seed");
    change_holding(deck, bolt, "sideboard", 2, "seed");
    refused = replace_holdings(
        deck,
        [
            HoldingEntry(oracle_id=bolt, zone="main", count=3, tags=["burn"]),
            HoldingEntry(oracle_id=cmdr, zone="commander", count=1, roles=["commander"])
        ],
        "Imported from mtgdeck1"
    );
    assert refused == [];
    assert _held(deck) == {(bolt, "main"): 3, (cmdr, "commander"): 1};
    imported = [(n.oracle_id, n.zone, n.before, n.after) for n in deck.history if n.reason == "Imported from mtgdeck1"];
    assert sorted(imported) == sorted([(bolt, "main", 4, 3), (cmdr, "commander", 0, 1), (bolt, "sideboard", 2, 0)]);
    by_zone = {c.zone: c for c in deck_view(deck).cards};
    assert by_zone["main"].tags == ["burn"];
    assert by_zone["commander"].roles == ["commander"];
}

test "replace_holdings lists refused entries and holds the rest" {
    deck = _deck("Holdings replace refusal test");
    bolt = _card("holdings-test-bolt", "Test Bolt");
    refused = replace_holdings(
        deck,
        [
            HoldingEntry(oracle_id=bolt, zone="main", count=4),
            HoldingEntry(oracle_id=bolt, zone="bogus_zone", count=1),
            HoldingEntry(oracle_id="not-a-card", zone="main", count=1)
        ],
        "import"
    );
    assert len(refused) == 2;
    assert _held(deck) == {(bolt, "main"): 4};
}
