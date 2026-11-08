"""Search the catalogue and add cards to one deck.

The web twin of the card search MCP app (#68, ui/mockups/card_search.html):
each hit shows how many copies the deck already holds, and every add
reports the change back (here to the deck page, there to Claude).
"""

import "./card_search.css";
import from .mana_cost { ManaCost }

sv import from decks { DeckView, DeckCard, AddCard }
sv import from cards { CardHit, search_cards }

def:pub CardSearch(deckId: str, cards: list[DeckCard], onChanged: Callable[[DeckView], None]) -> JsxElement {
    has query: str = "",
        lastQuery: str = "",
        hits: list[CardHit] = [],
        searched: bool = False,
        failed: bool = False,
        toast: str = "";

    async def runSearch(e: FormEvent) -> None;
    async def addCard(hit: CardHit, zone: str) -> None;

    def heldIn(oracleId: str, zone: str) -> int {
        total = 0;
        for c in cards {
            if c.oracle_id == oracleId and c.zone == zone {
                total += c.count;
            }
        }
        return total;
    }

    return
        <section aria-label="Add cards">
            <h2>Add cards</h2>
            <form onSubmit={runSearch} className="cs-search">
                <input
                    type="search"
                    aria-label="Search cards"
                    placeholder="Card name, type or rules text"
                    value={query}
                    onChange={lambda e: ChangeEvent { query = e.target.value; }}
                />
                <button type="submit" className="primary">Search</button>
            </form>
            {<div className="toast" role="status">{toast}</div> if toast else None}
            {if failed {
                <p className="empty" role="alert">Card search isn't available right now. The catalogue may need rebuilding. The deck is unchanged.</p>
            } elif searched and len(hits) == 0 {
                <p className="empty">{"No cards match “" + lastQuery + "”. Every word must match the start of a word in the name, type or rules text."}</p>
            } elif searched {
                <p className="cs-count">{str(len(hits)) + (" card matches" if len(hits) == 1 else " cards match") + " “" + lastQuery + "”"}</p>
            }}
            <ul className="cs-hits">
                {for hit in hits {
                    <li key={hit.oracle_id} className="cs-hit">
                        <div className="cs-title">
                            <span className="cs-name">{hit.name}</span>
                            <span className="cs-cost"><ManaCost cost={hit.mana_cost}/></span>
                            <span className="cs-type">{hit.type_line}</span>
                            {for zone in ["main", "sideboard"] {
                                if heldIn(hit.oracle_id, zone) > 0 {
                                    <span key={zone} className="pill ok">{str(heldIn(hit.oracle_id, zone)) + " in " + zone}</span>
                                }
                            }}
                        </div>
                        <div className="cs-text">{hit.text}</div>
                        <div className="cs-actions">
                            <button
                                aria-label={"Add " + hit.name + " to main deck"}
                                onClick={lambda _e: MouseEvent { addCard(hit, "main"); }}
                            >
                                + Main
                            </button>
                            <button
                                aria-label={"Add " + hit.name + " to sideboard"}
                                onClick={lambda _e: MouseEvent { addCard(hit, "sideboard"); }}
                            >
                                + Side
                            </button>
                        </div>
                    </li>
                }}
            </ul>
        </section>;
}
