"""Decks view: list your decks and create a new one."""

import from .deck_detail { DeckDetail }

sv import from decks { Deck, CreateDeck, ListDecks }

def:pub app -> JsxElement {
    has decks: list[Deck] = [],
        name: str = "",
        error: str = "",
        openDeckId: str = "";

    can with entry {
        loadDecks();
    }

    async def loadDecks -> None;
    async def createDeck(e: FormEvent) -> None;

    def closeDeck {
        openDeckId = "";
        loadDecks();
    }

    if openDeckId {
        return
            <main
                style={{
                    "maxWidth": "860px",
                    "margin": "2rem auto",
                    "padding": "0 1rem",
                    "fontFamily": "system-ui, -apple-system, sans-serif"
                }}
            >
                <DeckDetail key={openDeckId} deckId={openDeckId} onBack={closeDeck}/>
            </main>;
    }

    return
        <main
            style={{
                "maxWidth": "640px",
                "margin": "2rem auto",
                "padding": "0 1rem",
                "fontFamily": "system-ui, -apple-system, sans-serif"
            }}
        >
            <h1>Decks</h1>
            <form
                onSubmit={createDeck}
                style={{"display": "flex", "gap": "0.5rem", "marginBottom": "1.5rem"}}
            >
                <input
                    type="text"
                    aria-label="Deck name"
                    value={name}
                    onChange={lambda e: ChangeEvent { name = e.target.value; }}
                    placeholder="New deck name"
                    style={{"flex": "1", "padding": "0.5rem"}}
                />
                <button type="submit" style={{"padding": "0.5rem 1rem"}}>
                    Create deck
                </button>
            </form>
            {<p role="alert" style={{"color": "#b00020"}}>{error}</p> if error else None}
            {<p>No decks yet.</p> if len(decks) == 0 else None}
            <ul style={{"listStyle": "none", "padding": "0"}}>
                {[
                    <li
                        key={jid(deck)}
                        style={{"padding": "0.5rem 0", "borderBottom": "1px solid #ddd"}}
                    >
                        <a
                            href="#"
                            onClick={lambda e: MouseEvent { e.preventDefault(); openDeckId = jid(deck); }}
                        >
                            {deck.name}
                        </a>
                    </li>
                    for deck in decks
                ]}
            </ul>
        </main>;
}
