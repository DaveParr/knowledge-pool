"""Handlers for the Decks view."""

impl app.loadDecks -> None {
    result = root spawn ListDecks();
    decks = result.reports[0] if result.reports else [];
}

impl app.createDeck(e: FormEvent) -> None {
    e.preventDefault();
    if not name.strip() {
        error = "A deck needs a name.";
        return;
    }
    error = "";
    root spawn CreateDeck(name=name);
    name = "";
    await loadDecks();
}
