"""Handlers for card search."""

impl CardSearch.runSearch(e: FormEvent) -> None {
    e.preventDefault();
    toast = "";
    q = query.strip();
    if not q {
        hits = [];
        searched = False;
        failed = False;
        return;
    }
    try {
        hits = await search_cards(q);
        failed = False;
    } except Exception {
        hits = [];
        failed = True;
    }
    lastQuery = q;
    searched = True;
}

impl CardSearch.addCard(hit: CardHit, zone: str) -> None {
    result = root spawn AddCard(deck_id=deckId, oracle_id=hit.oracle_id, count=1, zone=zone);
    if not result.reports {
        toast = "";
        return;
    }
    view = result.reports[0];
    now = 0;
    for c in view.cards {
        if c.oracle_id == hit.oracle_id and c.zone == zone {
            now += c.count;
        }
    }
    where = "main deck" if zone == "main" else "sideboard";
    toast = "Added 1 " + hit.name + " to " + where + " (now " + str(now) + ").";
    onChanged(view);
}
