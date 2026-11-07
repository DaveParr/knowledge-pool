"""Decks view: list your decks and create a new one."""

import from .deck_detail { DeckDetail }
import from .export_menu { ExportMenu }

sv import from decks { Deck, FormatInfo, CreateDeck, ListDecks, list_formats }
sv import from deck_io { CreateDeckFromList }

def:pub app -> JsxElement {
    has decks: list[Deck] = [],
        name: str = "",
        error: str = "",
        openDeckId: str = "",
        importOpen: bool = False,
        importFormat: str = "moxfield",
        importText: str = "",
        importNotes: list[str] = [],
        importPlayFormat: str = "",
        formats: list[FormatInfo] = [];

    can with entry {
        loadDecks();
    }

    async def loadDecks -> None;
    async def createDeck(e: FormEvent) -> None;
    async def createFromList -> None;

    def closeDeck {
        openDeckId = "";
        importNotes = [];
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
                <DeckDetail key={openDeckId} deckId={openDeckId} importNotes={importNotes} onBack={closeDeck}/>
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
            <form onSubmit={createDeck} style={{"marginBottom": "1.5rem"}}>
                <div style={{"display": "flex", "gap": "0.5rem"}}>
                    <input
                        type="text"
                        aria-label="Deck name"
                        value={name}
                        onChange={lambda e: ChangeEvent { name = e.target.value; }}
                        placeholder={"Deck name (optional for mtgdeck/1)" if importOpen else "New deck name"}
                        style={{"flex": "1", "padding": "0.5rem"}}
                    />
                    <button type="submit" style={{"padding": "0.5rem 1rem"}}>
                        {"Create from list" if importOpen else "Create deck"}
                    </button>
                    <button
                        type="button"
                        aria-expanded={importOpen}
                        aria-controls="import-list"
                        onClick={lambda _e: MouseEvent { importOpen = not importOpen; error = ""; }}
                        style={{"padding": "0.5rem 0.75rem"}}
                    >
                        {"Import list ▴" if importOpen else "Import list ▾"}
                    </button>
                </div>
                {<div id="import-list" style={{"marginTop": "0.5rem"}}>
                    <div style={{"display": "flex", "gap": "1rem", "marginBottom": "0.5rem"}}>
                        <label>
                            {"List type "}
                            <select
                                aria-label="Import format"
                                value={importFormat}
                                onChange={lambda e: ChangeEvent { importFormat = e.target.value; }}
                            >
                                <option value="moxfield">Moxfield</option>
                                <option value="arena">MTGA/MTGO</option>
                                <option value="text">Plain text</option>
                                <option value="mtgdeck1">mtgdeck/1</option>
                            </select>
                        </label>
                        <label>
                            {"Play format "}
                            <select
                                aria-label="Play format"
                                value={importPlayFormat}
                                onChange={lambda e: ChangeEvent { importPlayFormat = e.target.value; }}
                            >
                                <option value="">{"From the list (mtgdeck/1), else Standard" if importFormat == "mtgdeck1" else "Standard"}</option>
                                {[<option key={f.name} value={f.name}>{f.label}</option> for f in formats if f.name != "standard" or importFormat == "mtgdeck1"]}
                            </select>
                        </label>
                    </div>
                    <textarea
                        aria-label="Deck list to import"
                        placeholder="Paste a deck list"
                        value={importText}
                        onChange={lambda e: ChangeEvent { importText = e.target.value; }}
                        style={{"width": "100%", "height": "8rem", "boxSizing": "border-box"}}
                    />
                </div> if importOpen else None}
            </form>
            {<p role="alert" style={{"color": "#b00020"}}>{error}</p> if error else None}
            {<p>No decks yet.</p> if len(decks) == 0 else None}
            <ul style={{"listStyle": "none", "padding": "0"}}>
                {[
                    <li
                        key={jid(deck)}
                        style={{
                            "padding": "0.5rem 0", "borderBottom": "1px solid #ddd",
                            "display": "flex", "justifyContent": "space-between", "alignItems": "center"
                        }}
                    >
                        <a
                            href="#"
                            onClick={lambda e: MouseEvent { e.preventDefault(); openDeckId = jid(deck); }}
                        >
                            {deck.name}
                        </a>
                        <ExportMenu deckId={jid(deck)} deckName={deck.name}/>
                    </li>
                    for deck in decks
                ]}
            </ul>
        </main>;
}
