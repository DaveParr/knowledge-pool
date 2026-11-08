"""Walker tests for creating and listing decks."""

import from decks { Deck, CreateDeck, ListDecks }

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
