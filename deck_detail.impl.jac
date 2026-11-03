"""Handlers for the deck view."""

impl DeckDetail.loadDeck -> None {
    formats = await list_formats();
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

impl DeckDetail.addCard(oracleId: str, zone: str) -> None {
    result = root spawn AddCard(deck_id=deckId, oracle_id=oracleId, count=1, zone=zone);
    if result.reports {
        deck = result.reports[0];
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
}

impl DeckDetail.removeCard(oracleId: str, zone: str) -> None {
    result = root spawn RemoveCard(deck_id=deckId, oracle_id=oracleId, zone=zone);
    if result.reports {
        deck = result.reports[0];
    }
}

impl DeckDetail.setFormat(value: str) -> None {
    result = root spawn SetDeckFormat(deck_id=deckId, format=value);
    if result.reports {
        deck = result.reports[0];
    }
}

impl DeckDetail.runExport -> None {
    result = root spawn DeckExport(deck_id=deckId, format=exportFormat);
    # DeckExport inherits DeckAction's `reports: list[DeckView]` but actually
    # reports ExportResult; cast through `any` at this use site rather than
    # widening deck_io.sv.jac's declared report type (out of scope here).
    exportText = ((result.reports[0] as any).content as str) if result.reports else "";
}

impl DeckDetail.runImport -> None {
    result = root spawn DeckImport(deck_id=deckId, format=importFormat, text=importText);
    # Same inherited-reports mismatch as runExport: DeckImport actually
    # reports ImportResult, not DeckView.
    if result.reports {
        outcome = result.reports[0] as any;
        deck = outcome.deck as DeckView;
        unresolved = outcome.unresolved as list[str];
    }
}
