"""Handlers for the Decks view."""

impl app.loadDecks -> None {
    if not formats {
        formats = await list_formats();
    }
    try {
        result = root spawn ListDecks();
        decks = result.reports[0] if result.reports else [];
        await checkWhenEmpty(result.reports);
    } except Exception {
        await checkSession();
    }
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
    try {
        result = root spawn CreateDeck(name=name);
        await checkWhenEmpty(result.reports);
    } except Exception {
        await checkSession();
    }
    name = "";
    await loadDecks();
}

impl app.createFromList -> None {
    if not importText.strip() {
        error = "Paste a deck list to import.";
        return;
    }
    try {
        result = root spawn CreateDeckFromList(name=name, format=importFormat, text=importText, play_format=importPlayFormat);
    } except Exception {
        await checkSession();
        return;
    }
    if await checkWhenEmpty(result.reports) {
        return;
    }
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
