"""My collection: the cards the signed-in user has, with counts, and the history
of changes. Its own view, so a redesign can place it anywhere: the Decks page
only offers a way in (`onBack` returns there)."""

import "./card_search.css";
import from .mana_cost { ManaCost }
import from .walker_failure { failureMessage, REFUSED_LINE }

import from collection { GetCollection, ChangeCollection, ImportCollection }
import from collection_views { CollectionLine, CollectionView, ImportCollectionResult, MODE_ADD, MODE_REMOVE, MODE_SET }
import from edit_reason { WEB_COLLECTION_REASON }
import from walker_errors { WalkerError }
import from cards { CardHit, CardSearch, search_cards }

"""One card of the collection: its count, quick +1 and −1, add or remove N
copies, set the count, or remove them all."""
def CollectionRow(line: CollectionLine, onChange: Callable[[str, int, str], None]) -> JsxElement {
    has copies: str = "1",
        target: str = str(line.count);

    """The whole number in `text`, or -1 when it is not one."""
    def wholeNumber(text: str) -> int {
        if not text.strip() or not text.strip().isdigit() {
            return -1;
        }
        return int(text.strip());
    }

    def apply(text: str, mode: str) {
        n = wholeNumber(text);
        if n >= 0 {
            onChange(line.oracle_id, n, mode);
        }
    }

    return
        <li className="fe-deck">
            <span>{line.name}</span>
            <span className="pill">{"× " + str(line.count)}</span>
            <button
                aria-label={"Add one " + line.name}
                onClick={lambda (_e: MouseEvent) { onChange(line.oracle_id, 1, MODE_ADD); }}
            >
                +
            </button>
            <button
                aria-label={"Remove one " + line.name}
                onClick={lambda (_e: MouseEvent) { onChange(line.oracle_id, 1, MODE_REMOVE); }}
            >
                −
            </button>
            <input
                type="number"
                min="1"
                aria-label={"Copies of " + line.name}
                value={copies}
                onChange={lambda (e: ChangeEvent) { copies = e.target.value; }}
            />
            <button
                aria-label={"Add copies of " + line.name}
                onClick={lambda (_e: MouseEvent) { apply(copies, MODE_ADD); }}
            >
                Add
            </button>
            <button
                aria-label={"Remove copies of " + line.name}
                onClick={lambda (_e: MouseEvent) { apply(copies, MODE_REMOVE); }}
            >
                Remove
            </button>
            <input
                type="number"
                min="0"
                aria-label={"Count of " + line.name}
                value={target}
                onChange={lambda (e: ChangeEvent) { target = e.target.value; }}
            />
            <button
                aria-label={"Set count of " + line.name}
                onClick={lambda (_e: MouseEvent) { apply(target, MODE_SET); }}
            >
                Set count
            </button>
            <button
                aria-label={"Remove all of " + line.name}
                onClick={lambda (_e: MouseEvent) { onChange(line.oracle_id, 0, MODE_SET); }}
            >
                Remove all
            </button>
        </li>;
}

def:pub CollectionPage(onBack: Callable[[], None]) -> JsxElement {
    has view: CollectionView | None = None,
        error: str = "",
        query: str = "",
        hits: list[CardHit] = [],
        searched: bool = False,
        importFormat: str = "text",
        importText: str = "",
        notImported: list[str] = [];

    can with entry {
        load();
    }

    async def load {
        result = root spawn GetCollection();
        show(result.reports);
    }

    def show(reports: list[CollectionView | WalkerError]) {
        why = failureMessage(reports);
        error = why;
        if not why {
            view = reports[0] as CollectionView;
        }
    }

    async def change(oracleId: str, count: int, mode: str) {
        result = root spawn ChangeCollection(oracle_id=oracleId, count=count, mode=mode, reason=WEB_COLLECTION_REASON);
        show(result.reports);
    }

    async def runImport(e: FormEvent) {
        e.preventDefault();
        if not importText.strip() {
            return;
        }
        result = root spawn ImportCollection(format=importFormat, text=importText);
        why = failureMessage(result.reports);
        error = why;
        if not why {
            done = result.reports[0] as ImportCollectionResult;
            view = done.collection;
            notImported = done.unresolved;
            importText = "";
        }
    }

    async def runSearch(e: FormEvent) {
        e.preventDefault();
        q = query.strip();
        if not q {
            hits = [];
            searched = False;
            return;
        }
        try {
            found = await search_cards(q);
            why = failureMessage([found]);
            hits = [] if why else found.hits;
            error = why or found.error;
        } except Exception {
            hits = [];
            error = REFUSED_LINE;
        }
        searched = True;
    }

    return
        <main className="page narrow">
            <p><a href="#" onClick={lambda (e: MouseEvent) { e.preventDefault(); onBack(); }}>← Decks</a></p>
            <h1>My collection</h1>
            <p className="fe-note">The cards you have, counted per card. Changing a deck never changes it.</p>
            {<p role="alert" className="error">{error}</p> if error else None}
            <form onSubmit={runSearch} className="cs-search">
                <input
                    type="search"
                    aria-label="Search cards to add to your collection"
                    placeholder="Card name, type or rules text"
                    value={query}
                    onChange={lambda (e: ChangeEvent) { query = e.target.value; }}
                />
                <button type="submit" className="primary">Search</button>
            </form>
            {<p className="empty">No cards match.</p> if searched and len(hits) == 0 and not error else None}
            <ul className="cs-hits">
                {for hit in hits {
                    <li key={hit.oracle_id} className="cs-hit">
                        <div className="cs-title">
                            <span className="cs-name">{hit.name}</span>
                            <span className="cs-cost"><ManaCost cost={hit.mana_cost}/></span>
                            <span className="cs-type">{hit.type_line}</span>
                        </div>
                        <div className="cs-actions">
                            <button
                                aria-label={"Add " + hit.name + " to my collection"}
                                onClick={lambda (_e: MouseEvent) { change(hit.oracle_id, 1, MODE_ADD); }}
                            >
                                + Collection
                            </button>
                        </div>
                    </li>
                }}
            </ul>
            <form onSubmit={runImport} className="fe-import">
                <label>
                    {"List type "}
                    <select
                        aria-label="Import format"
                        value={importFormat}
                        onChange={lambda (e: ChangeEvent) { importFormat = e.target.value; }}
                    >
                        <option value="text">Plain text</option>
                        <option value="moxfield">Moxfield</option>
                        <option value="arena">MTGA/MTGO</option>
                        <option value="mtgdeck1">mtgdeck/1</option>
                        <option value="mtgjson">MTGJSON deck</option>
                    </select>
                </label>
                <textarea
                    aria-label="List to import into my collection"
                    placeholder="Paste a card list to add to your collection"
                    value={importText}
                    onChange={lambda (e: ChangeEvent) { importText = e.target.value; }}
                    rows={6}
                />
                <button type="submit" className="primary">Import list</button>
            </form>
            {<div>
                <p>Not imported:</p>
                <ul aria-label="Not imported">
                    {[<li key={str(i)}>{line}</li> for (i, line) in enumerate(notImported)]}
                </ul>
            </div> if notImported else None}
            <h2>{"Cards" if view is None else "Cards (" + str(view.total) + ")"}</h2>
            {<p className="empty">Nothing in your collection yet.</p> if view is not None and len(view.cards) == 0 else None}
            <ul className="fe-decks" aria-label="My collection">
                {for line in (view.cards if view is not None else []) {
                    <CollectionRow key={line.oracle_id + ":" + str(line.count)} line={line} onChange={change}/>
                }}
            </ul>
            <h2>History</h2>
            {<p className="empty">No changes yet.</p> if view is not None and len(view.history) == 0 else None}
            <ul aria-label="Collection history">
                {for note in (view.history[::-1] if view is not None else []) {
                    <li key={note.at + note.oracle_id}>
                        {note.name + ": " + str(note.before) + " → " + str(note.after) + " (" + note.reason + ")"}
                    </li>
                }}
            </ul>
        </main>;
}
