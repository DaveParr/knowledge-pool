"""My collection: the cards the signed-in user has, with counts, and the history
of changes. Its own view, so a redesign can place it anywhere: the Decks page
only offers a way in (`onBack` returns there)."""

import "./card_search.css";
import from .mana_cost { ManaCost }
import from .walker_failure { failureMessage, REFUSED_LINE }

import from collection { GetCollection, ChangeCollection }
import from collection_views { CollectionView, MODE_ADD, MODE_REMOVE, MODE_SET }
import from edit_reason { WEB_COLLECTION_REASON }
import from walker_errors { WalkerError }
import from cards { CardHit, CardSearch, search_cards }

def:pub CollectionPage(onBack: Callable[[], None]) -> JsxElement {
    has view: CollectionView | None = None,
        error: str = "",
        query: str = "",
        hits: list[CardHit] = [],
        searched: bool = False;

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
            <h2>{"Cards" if view is None else "Cards (" + str(view.total) + ")"}</h2>
            {<p className="empty">Nothing in your collection yet.</p> if view is not None and len(view.cards) == 0 else None}
            <ul className="fe-decks" aria-label="My collection">
                {for line in (view.cards if view is not None else []) {
                    <li key={line.oracle_id} className="fe-deck">
                        <span>{line.name}</span>
                        <span className="pill">{"× " + str(line.count)}</span>
                        <button
                            aria-label={"Add one " + line.name}
                            onClick={lambda (_e: MouseEvent) { change(line.oracle_id, 1, MODE_ADD); }}
                        >
                            +
                        </button>
                        <button
                            aria-label={"Remove one " + line.name}
                            onClick={lambda (_e: MouseEvent) { change(line.oracle_id, 1, MODE_REMOVE); }}
                        >
                            −
                        </button>
                        <button
                            aria-label={"Remove all of " + line.name}
                            onClick={lambda (_e: MouseEvent) { change(line.oracle_id, 0, MODE_SET); }}
                        >
                            Remove all
                        </button>
                    </li>
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
