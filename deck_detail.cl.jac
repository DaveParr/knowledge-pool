"""One deck: search real cards, add them, change counts, remove them."""

sv import from decks { DeckView, DeckCard, GetDeck, AddCard, SetCardCount, RemoveCard }
sv import from cards { CardHit, search_cards }

def:pub DeckDetail(deckId: str, onBack: Callable[[], None]) -> JsxElement {
    has deck: DeckView | None = None,
        query: str = "",
        hits: list[CardHit] = [],
        searched: bool = False;

    can with entry {
        loadDeck();
    }

    async def loadDeck -> None;
    async def runSearch(e: FormEvent) -> None;
    async def addCard(oracleId: str) -> None;
    async def setCount(oracleId: str, value: str) -> None;
    async def removeCard(oracleId: str) -> None;

    def back(_e: MouseEvent) {
        onBack();
    }

    if deck is None {
        return <p>Loading deck...</p>;
    }

    return
        <section>
            <button onClick={back} style={{"marginBottom": "1rem"}}>Back to decks</button>
            <h1>{deck.name}</h1>
            <p>{str(deck.total) + " cards"}</p>
            <table style={{"width": "100%", "borderCollapse": "collapse", "marginBottom": "2rem"}}>
                <tbody>
                    {[
                        <tr key={line.oracle_id} style={{"borderBottom": "1px solid #ddd"}}>
                            <td style={{"width": "5rem"}}>
                                <input
                                    type="number"
                                    min="0"
                                    aria-label={"Count of " + line.name}
                                    value={str(line.count)}
                                    onChange={lambda e: ChangeEvent { setCount(line.oracle_id, e.target.value); }}
                                    style={{"width": "4rem"}}
                                />
                            </td>
                            <td>{line.name}</td>
                            <td style={{"color": "#666"}}>{line.mana_cost}</td>
                            <td style={{"color": "#666"}}>{line.type_line}</td>
                            <td>
                                <button
                                    aria-label={"Remove " + line.name}
                                    onClick={lambda _e: MouseEvent { removeCard(line.oracle_id); }}
                                >
                                    Remove
                                </button>
                            </td>
                        </tr>
                        for line in deck.cards
                    ]}
                </tbody>
            </table>
            <h2>Add cards</h2>
            <form onSubmit={runSearch} style={{"display": "flex", "gap": "0.5rem"}}>
                <input
                    type="search"
                    aria-label="Search cards"
                    placeholder="Card name or rules text"
                    value={query}
                    onChange={lambda e: ChangeEvent { query = e.target.value; }}
                    style={{"flex": "1", "padding": "0.5rem"}}
                />
                <button type="submit">Search</button>
            </form>
            {<p>No cards found.</p> if searched and len(hits) == 0 else None}
            <ul style={{"listStyle": "none", "padding": "0"}}>
                {[
                    <li
                        key={hit.oracle_id}
                        style={{"padding": "0.5rem 0", "borderBottom": "1px solid #eee"}}
                    >
                        <button
                            aria-label={"Add " + hit.name}
                            onClick={lambda _e: MouseEvent { addCard(hit.oracle_id); }}
                            style={{"marginRight": "0.5rem"}}
                        >
                            Add
                        </button>
                        <strong>{hit.name}</strong>
                        <span style={{"color": "#666"}}>{" " + hit.mana_cost + " · " + hit.type_line}</span>
                        <div style={{"color": "#444", "fontSize": "0.9rem", "whiteSpace": "pre-line"}}>{hit.text}</div>
                    </li>
                    for hit in hits
                ]}
            </ul>
        </section>;
}
