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
        searched = False;
        return;
    }
    hits = await search_cards(query);
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

impl DeckDetail.runExport -> None {
    result = root spawn DeckExport(deck_id=deckId, format=exportFormat);
    exportText = result.reports[0].content if result.reports else "";
}

impl DeckDetail.runImport -> None {
    result = root spawn DeckImport(deck_id=deckId, format=importFormat, text=importText);
    if result.reports {
        outcome = result.reports[0];
        deck = outcome.deck;
        unresolved = outcome.unresolved;
    }
}
