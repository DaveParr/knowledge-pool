"""Handlers for the Decks view."""

impl app.loadDecks -> None {
    if not formats {
        try {
            formats = await list_formats();
        } except Exception as failure {
            error = thrownLine(failure);
            return;
        }
    }
    result = root spawn ListDecks();
    why = failureMessage(result.reports);
    if why {
        error = why;
        return;
    }
    error = "";
    decks = result.reports[0] if result.reports else [];
}

impl app.createDeck(e: FormEvent) -> None {
    e.preventDefault();
    if importOpen {
        await createFromList();
        return;
    }
    if not name.strip() {
        error = "A deck needs a name.";
        return;
    }
    error = "";
    created = root spawn CreateDeck(name=name);
    why = failureMessage(created.reports);
    if why {
        error = why;
        return;
    }
    name = "";
    await loadDecks();
}

impl app.createFromList -> None {
    if not importText.strip() {
        error = "Paste a deck list to import.";
        return;
    }
    result = root spawn CreateDeckFromList(name=name, format=importFormat, text=importText, play_format=importPlayFormat);
    why = failureMessage(result.reports);
    if why {
        error = why;
        return;
    }
    outcome = result.reports[0] as NewDeckResult;
    if not outcome.deck_id {
        missing = "";
        for line in outcome.unresolved {
            missing = line if missing == "" else missing + "; " + line;
        }
        error = "Nothing imported, so no deck was created. Didn't resolve: " + missing;
        return;
    }
    error = "";
    name = "";
    importText = "";
    importOpen = False;
    importNotes = outcome.unresolved;
    openDeckId = outcome.deck_id;
}
