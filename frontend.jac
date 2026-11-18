"""Decks view: list your decks and create a new one."""

import "./global.css";
import "./frontend.css";
import from .deck_detail { DeckDetail, formatName }
import from .export_panel { ExportPanel }
import from .walker_failure { failureMessage }
import from .session_bar { SessionBar }

import from decks { Deck, DeckSummary, FormatInfo, CreateDeck, ListDecks, ListOtherDecks, list_formats }
import from deck_io { CreateDeckFromList, NewDeckResult }

def:pub app -> JsxElement {
    has decks: list[Deck] = [],
        name: str = "",
        error: str = "",
        otherDecks: list[DeckSummary] = [],
        openDeckId: str = "",
        openReadOnly: bool = False,
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

    def formatLabel(format_name: str) -> str {
        return formatName(format_name, formats);
    }

    """Open a deck of the caller's own (`readOnly` False) or another user's."""
    def openDeck(deckId: str, readOnly: bool) {
        openReadOnly = readOnly;
        openDeckId = deckId;
    }

    """A copy was made: open it, as the caller's own deck."""
    def copied(deckId: str) {
        openDeck(deckId, False);
    }

    def closeDeck {
        openDeckId = "";
        importNotes = [];
        loadDecks();
    }

    if openDeckId {
        return
            <main className="page">
                <SessionBar/>
                <DeckDetail
                    key={openDeckId}
                    deckId={openDeckId}
                    importNotes={importNotes}
                    readOnly={openReadOnly}
                    onCopied={copied}
                    onBack={closeDeck}
                />
            </main>;
    }

    return
        <main className="page narrow">
            <SessionBar/>
            <h1>Decks</h1>
            <form onSubmit={createDeck} className="fe-create">
                <div className="fe-row">
                    <input
                        type="text"
                        aria-label="Deck name"
                        value={name}
                        onChange={lambda (e: ChangeEvent) { name = e.target.value; }}
                        placeholder={"Deck name (optional for mtgdeck/1 or MTGJSON)" if importOpen else "New deck name"}
                    />
                    <button type="submit" className="primary">
                        {"Create from list" if importOpen else "Create deck"}
                    </button>
                    <button
                        type="button"
                        aria-expanded={importOpen}
                        aria-controls="import-list"
                        onClick={lambda (_e: MouseEvent) { importOpen = not importOpen; error = ""; }}
                    >
                        {"Import list ▴" if importOpen else "Import list ▾"}
                    </button>
                </div>
                {<div id="import-list" className="fe-import">
                    <div className="fe-row fe-options">
                        <label>
                            {"List type "}
                            <select
                                aria-label="Import format"
                                value={importFormat}
                                onChange={lambda (e: ChangeEvent) { importFormat = e.target.value; }}
                            >
                                <option value="moxfield">Moxfield</option>
                                <option value="arena">MTGA/MTGO</option>
                                <option value="text">Plain text</option>
                                <option value="mtgdeck1">mtgdeck/1</option>
                                <option value="mtgjson">MTGJSON deck</option>
                            </select>
                        </label>
                        <label>
                            {"Play format "}
                            <select
                                aria-label="Play format"
                                value={importPlayFormat}
                                onChange={lambda (e: ChangeEvent) { importPlayFormat = e.target.value; }}
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
                        onChange={lambda (e: ChangeEvent) { importText = e.target.value; }}
                        rows={8}
                    />
                </div> if importOpen else None}
            </form>
            <p className="fe-note">Other users can see and copy the decks you make.</p>
            {<p role="alert" className="error">{error}</p> if error else None}
            {<p className="empty">No decks yet.</p> if len(decks) == 0 else None}
            <ul className="fe-decks">
                {[
                    <li key={jid(deck)} className="fe-deck">
                        <a
                            href="#"
                            onClick={lambda (e: MouseEvent) { e.preventDefault(); openDeck(jid(deck), False); }}
                        >
                            {deck.name}
                        </a>
                        <span className="pill">{formatLabel(deck.format)}</span>
                        <ExportPanel deckId={jid(deck)} deckName={deck.name}/>
                    </li>
                    for deck in decks
                ]}
            </ul>
            <h2>Other users' decks</h2>
            <p className="fe-note">Read-only. Open one to see it all, and copy it to make your own to change.</p>
            {<p className="empty">No other users' decks yet.</p> if len(otherDecks) == 0 else None}
            <ul className="fe-decks fe-others" aria-label="Other users' decks">
                {[
                    <li key={deck.id} className="fe-deck">
                        <a
                            href="#"
                            onClick={lambda (e: MouseEvent) { e.preventDefault(); openDeck(deck.id, True); }}
                        >
                            {deck.name}
                        </a>
                        <span className="pill">{formatLabel(deck.format)}</span>
                        <span className="fe-owner">{"by " + deck.owner}</span>
                    </li>
                    for deck in otherDecks
                ]}
            </ul>
        </main>;
}
