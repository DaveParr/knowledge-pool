"""Handlers for the deck view."""

impl DeckDetail.loadDeck -> None {
    formats = await list_formats();
    result = root spawn GetDeck(deck_id=deckId);
    show(result.reports);
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
    show(result.reports);
}

impl DeckDetail.removeCard(oracleId: str, zone: str) -> None {
    result = root spawn RemoveCard(deck_id=deckId, oracle_id=oracleId, zone=zone);
    show(result.reports);
}

impl DeckDetail.setFormat(value: str) -> None {
    result = root spawn SetDeckFormat(deck_id=deckId, format=value);
    show(result.reports);
}

impl DeckDetail.show(reports: list[DeckView | WalkerError]) -> None {
    why = failureMessage(reports);
    error = why;
    if not why {
        deck = reports[0] as DeckView;
    }
}

impl DeckDetail.copyDeck -> None {
    result = root spawn CopyOtherDeck(deck_id=deckId);
    why = failureMessage(result.reports);
    if why {
        error = why;
        return;
    }
    onCopied((result.reports[0] as DeckView).id);
}
