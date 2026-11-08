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
