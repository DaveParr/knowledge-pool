"""Handlers for the deck view."""

impl DeckDetail.loadDeck -> None {
    formats = await list_formats();
    result = root spawn GetDeck(deck_id=deckId);
    if result.reports {
        deck = result.reports[0];
    }
    await refreshAnalysis();
}

impl DeckDetail.refreshAnalysis -> None {
    result = root spawn AnalyzeDeck(deck_id=deckId);
    if result.reports {
        analysis = result.reports[0];
    }
}

impl DeckDetail.runSearch(e: FormEvent) -> None {
    e.preventDefault();
    if not query.strip() {
        hits = [];
        searchError = "";
        searched = False;
        return;
    }
    result: CardSearch | None = await search_cards(query);
    # None means the call itself failed (the client stub found no result).
    hits = result.hits if result is not None else [];
    searchError = result.error if result is not None else "Card search failed.";
    searched = True;
}

impl DeckDetail.addCard(oracleId: str, zone: str) -> None {
    result = root spawn AddCard(deck_id=deckId, oracle_id=oracleId, count=1, zone=zone);
    if result.reports {
        deck = result.reports[0];
    }
    await refreshAnalysis();
}

impl DeckDetail.setCount(oracleId: str, zone: str, value: str) -> None {
    if value == "" {
        return;
    }
    n = int(value);
    if n < 0 {
        return;
    }
    result = root spawn SetCardCount(deck_id=deckId, oracle_id=oracleId, count=n, zone=zone);
    if result.reports {
        deck = result.reports[0];
    }
    await refreshAnalysis();
}

impl DeckDetail.removeCard(oracleId: str, zone: str) -> None {
    result = root spawn RemoveCard(deck_id=deckId, oracle_id=oracleId, zone=zone);
    if result.reports {
        deck = result.reports[0];
    }
    await refreshAnalysis();
}

impl DeckDetail.setFormat(value: str) -> None {
    result = root spawn SetDeckFormat(deck_id=deckId, format=value);
    if result.reports {
        deck = result.reports[0];
    }
}
