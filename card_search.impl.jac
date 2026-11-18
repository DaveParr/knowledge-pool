"""Handlers for card search."""

impl AddCards.runSearch(e: FormEvent) -> None {
    e.preventDefault();
    toast = "";
    addError = "";
    q = query.strip();
    if not q {
        hits = [];
        searched = False;
        searchError = "";
        return;
    }
    result: CardSearch | None = await search_cards(q);
    # None means the call itself failed (the client stub found no result).
    hits = result.hits if result is not None else [];
    searchError = result.error if result is not None else "Card search failed.";
    lastQuery = q;
    searched = True;
}

impl AddCards.addCard(hit: CardHit, zone: str) -> None {
    result = root spawn AddCard(deck_id=deckId, oracle_id=hit.oracle_id, count=1, zone=zone);
    reports: list[DeckView | WalkerError] = result.reports;
    await checkWhenEmpty(reports);
    why = failureMessage(reports);
    if why {
        toast = "";
        addError = why;
        return;
    }
    addError = "";
    view = reports[0] as DeckView;
    now = 0;
    for c in view.cards {
        if c.oracle_id == hit.oracle_id and c.zone == zone {
            now += c.count;
        }
    }
    where = {"main": "main deck", "sideboard": "sideboard", "commander": "commander zone", "companion": "companion zone"}.get(zone, zone);
    toast = "Added 1 " + hit.name + " to " + where + " (now " + str(now) + ").";
    onChanged(view);
}
