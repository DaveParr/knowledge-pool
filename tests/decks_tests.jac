"""Walker tests for creating and listing decks."""

import from decks { Deck, CreateDeck, ListDecks }
import from walker_errors { WalkerError }

test "create deck reports a deck with a trimmed name" {
    result = root spawn CreateDeck(name="  Mono Red  ");
    deck = result.reports[0] as Deck;
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
    assert len(result.reports) == 1;
    err = result.reports[0];
    assert isinstance(err, WalkerError);
    assert err.code == "blank-name";
    assert len([root-->[?:Deck]]) == before;
}
