"""Handlers for the deck view."""

impl DeckDetail.loadDeck -> None {
    result = root spawn GetDeck(deck_id=deckId);
    if result.reports {
        deck = result.reports[0];
    }
}

impl DeckDetail.runSearch(e: FormEvent) -> None {
    e.preventDefault();
    if not query.strip() {
        hits = [];
        searched = False;
        return;
    }
    hits = await search_cards(query);
    searched = True;
}

impl DeckDetail.addCard(oracleId: str) -> None {
    result = root spawn AddCard(deck_id=deckId, oracle_id=oracleId, count=1);
    if result.reports {
        deck = result.reports[0];
    }
}

impl DeckDetail.setCount(oracleId: str, value: str) -> None {
    if value == "" {
        return;
    }
    n = int(value);
    if n < 0 {
        return;
    }
    result = root spawn SetCardCount(deck_id=deckId, oracle_id=oracleId, count=n);
    if result.reports {
        deck = result.reports[0];
    }
}

impl DeckDetail.removeCard(oracleId: str) -> None {
    result = root spawn RemoveCard(deck_id=deckId, oracle_id=oracleId);
    if result.reports {
        deck = result.reports[0];
    }
}
