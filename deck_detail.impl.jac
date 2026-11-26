"""Handlers for the deck view."""

impl DeckDetail.loadDeck -> None {
    try {
        loaded = await list_formats();
        why = failureMessage([loaded]);
        if why {
            error = why;
            return;
        }
        formats = loaded;
    } except Exception {
        error = REFUSED_LINE;
        return;
    }
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
    result = root spawn EditDeck(deck_id=deckId, changes=[{"oracle_id": oracleId, "count": n, "zone": zone, "reason": WEB_EDIT_REASON}]);
    show(result.reports);
}

impl DeckDetail.removeCard(oracleId: str, zone: str) -> None {
    result = root spawn EditDeck(deck_id=deckId, changes=[{"oracle_id": oracleId, "count": 0, "zone": zone, "reason": WEB_EDIT_REASON}]);
    show(result.reports);
}

impl DeckDetail.setFormat(value: str) -> None {
    result = root spawn EditDeck(deck_id=deckId, format=value);
    show(result.reports);
}

impl DeckDetail.show(reports: list[DeckView | WalkerError]) -> None {
    why = failureMessage(reports);
    error = why;
    if not why {
        deck = reports[0] as DeckView;
        # Changes the walker refused are listed on the view; the rest were applied.
        error = "; ".join(deck.rejected);
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

impl DeckDetail.renameDeck -> None {
    result = root spawn EditDeck(deck_id=deckId, name=draft);
    why = failureMessage(result.reports);
    error = why;
    if not why {
        deck = result.reports[0] as DeckView;
        renaming = False;
    }
}

impl DeckDetail.deleteDeck -> None {
    result = root spawn DeleteDeck(deck_id=deckId);
    why = failureMessage(result.reports);
    if why {
        error = why;
        confirmingDelete = False;
        return;
    }
    onBack();
}
