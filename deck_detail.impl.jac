"""Handlers for the deck view."""

impl DeckDetail.loadDeck -> None {
    formats = await list_formats();
    result = root spawn GetDeck(deck_id=deckId);
    await show(result.reports);
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
    await show(result.reports);
}

impl DeckDetail.removeCard(oracleId: str, zone: str) -> None {
    result = root spawn RemoveCard(deck_id=deckId, oracle_id=oracleId, zone=zone);
    await show(result.reports);
}

impl DeckDetail.setFormat(value: str) -> None {
    result = root spawn SetDeckFormat(deck_id=deckId, format=value);
    await show(result.reports);
}

impl DeckDetail.show(reports: list[DeckView | WalkerError]) -> None {
    await checkWhenEmpty(reports);
    why = failureMessage(reports);
    error = why;
    if not why {
        deck = reports[0] as DeckView;
    }
}
