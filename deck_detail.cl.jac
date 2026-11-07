"""One deck: search real cards, add them, change counts, remove them."""

sv import from decks {
    DeckView, DeckCard, FormatInfo, DeckAnalysis, GetDeck, SetDeckFormat, AddCard, SetCardCount, RemoveCard,
    AnalyzeDeck, list_formats
}
sv import from deck_io { DeckExport, DeckImport }
sv import from legality { Violation }
sv import from mana { ManaProfile }
sv import from cards { CardHit, search_cards }

def:pub DeckDetail(deckId: str, onBack: Callable[[], None]) -> JsxElement {
    has deck: DeckView | None = None,
        analysis: DeckAnalysis | None = None,
        query: str = "",
        hits: list[CardHit] = [],
        searched: bool = False,
        formats: list[FormatInfo] = [],
        exportFormat: str = "mtgdeck1",
        exportText: str = "",
        importFormat: str = "mtgdeck1",
        importText: str = "",
        unresolved: list[str] = [];

    can with entry {
        loadDeck();
    }

    async def loadDeck -> None;
    async def refreshAnalysis -> None;
    async def runSearch(e: FormEvent) -> None;
    async def addCard(oracleId: str, zone: str) -> None;
    async def setCount(oracleId: str, zone: str, value: str) -> None;
    async def removeCard(oracleId: str, zone: str) -> None;
    async def setFormat(value: str) -> None;
    async def runExport -> None;
    async def runImport -> None;

    def back(_e: MouseEvent) {
        onBack();
    }

    def curveBarWidth(count: int, max_count: int) -> str {
        pct = round(100 * count / max_count) if max_count > 0 else 0;
        return str(pct) + "%";
    }

    if deck is None {
        return <p>Loading deck...</p>;
    }

    curveBuckets = analysis.curve.buckets if analysis is not None else None;
    maxBucketCount = max(
        curveBuckets["0"], curveBuckets["1"], curveBuckets["2"], curveBuckets["3"],
        curveBuckets["4"], curveBuckets["5"], curveBuckets["6"], curveBuckets["7+"], 1
    ) if curveBuckets is not None else 1;

    return
        <section>
            <button onClick={back} style={{"marginBottom": "1rem"}}>Back to decks</button>
            <h1>{deck.name}</h1>
            <p>
                <label>
                    {"Format "}
                    <select
                        aria-label="Format"
                        value={deck.format}
                        onChange={lambda e: ChangeEvent { setFormat(e.target.value); }}
                    >
                        {[<option key={f.name} value={f.name}>{f.label}</option> for f in formats]}
                    </select>
                </label>
                {"  " + str(deck.main_total) + " main, " + str(deck.sideboard_total) + " sideboard"}
            </p>
            <div
                role="status"
                style={{
                    "padding": "0.75rem 1rem",
                    "marginBottom": "1rem",
                    "borderRadius": "6px",
                    "backgroundColor": "#e8f5e9" if deck.legal else "#fdecea",
                    "color": "#1b5e20" if deck.legal else "#8a1c13"
                }}
            >
                <strong>{"Legal" if deck.legal else "Not legal"}</strong>
                <ul style={{"margin": "0.25rem 0 0", "paddingLeft": "1.25rem"}}>
                    {[<li key={str(i)}>{v.message}</li> for (i, v) in enumerate(deck.violations)]}
                </ul>
            </div>
            <div style={{"marginBottom": "1rem"}}>
                <strong>{"Lands: " + str(deck.mana.land_count)}</strong>
                <ul style={{"margin": "0.25rem 0 0", "paddingLeft": "1.25rem"}}>
                    {[
                        <li key={colour}>
                            {
                                colour + ": " + str(deck.mana.pips[colour]) + " pips, "
                                + str(deck.mana.sources[colour]) + " sources"
                            }
                        </li>
                        for colour in ["W", "U", "B", "R", "G"]
                    ]}
                </ul>
            </div>
            {
                <section style={{"marginBottom": "2rem"}}>
                    <h2>Mana curve</h2>
                    <p>{"Average mana value (non-land): " + f"{analysis.curve.average_mv:.2f}"}</p>
                    <div>
                        {[
                            <div
                                key={label}
                                style={{"display": "flex", "alignItems": "center", "gap": "0.5rem", "marginBottom": "0.15rem"}}
                            >
                                <span style={{"width": "2rem"}}>{label}</span>
                                <div style={{
                                    "backgroundColor": "#1976d2",
                                    "height": "1rem",
                                    "width": curveBarWidth(count, maxBucketCount)
                                }}/>
                                <span>{str(count)}</span>
                            </div>
                            # CURVE_BUCKETS order from the server (0..6, 7+) is what drives display order here.
                            for (label, count) in analysis.curve.buckets.items()
                        ]}
                    </div>
                </section>
                if analysis is not None else None
            }
            <table style={{"width": "100%", "borderCollapse": "collapse", "marginBottom": "2rem"}}>
                <tbody>
                    {[
                        <tr key={line.zone + line.oracle_id} style={{"borderBottom": "1px solid #ddd"}}>
                            <td style={{"width": "5rem"}}>
                                <input
                                    type="number"
                                    min="0"
                                    aria-label={"Count of " + line.name + " in " + line.zone}
                                    value={str(line.count)}
                                    onChange={lambda e: ChangeEvent { setCount(line.oracle_id, line.zone, e.target.value); }}
                                    style={{"width": "4rem"}}
                                />
                            </td>
                            <td>{line.name}</td>
                            <td style={{"color": "#666"}}>{"Sideboard" if line.zone == "sideboard" else ""}</td>
                            <td style={{"color": "#666"}}>{line.mana_cost}</td>
                            <td style={{"color": "#666"}}>{line.type_line}</td>
                            <td>
                                {[
                                    <span
                                        key={tag}
                                        style={{
                                            "display": "inline-block",
                                            "padding": "0.1rem 0.5rem",
                                            "marginRight": "0.25rem",
                                            "marginBottom": "0.15rem",
                                            "borderRadius": "999px",
                                            "backgroundColor": "#eee",
                                            "color": "#444",
                                            "fontSize": "0.8rem"
                                        }}
                                    >
                                        {tag}
                                    </span>
                                    for tag in line.oracle_tags
                                ]}
                            </td>
                            <td>
                                <button
                                    aria-label={"Remove " + line.name + " from " + line.zone}
                                    onClick={lambda _e: MouseEvent { removeCard(line.oracle_id, line.zone); }}
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
                            onClick={lambda _e: MouseEvent { addCard(hit.oracle_id, "main"); }}
                            style={{"marginRight": "0.25rem"}}
                        >
                            Add
                        </button>
                        <button
                            aria-label={"Add " + hit.name + " to sideboard"}
                            onClick={lambda _e: MouseEvent { addCard(hit.oracle_id, "sideboard"); }}
                            style={{"marginRight": "0.5rem"}}
                        >
                            Side
                        </button>
                        <strong>{hit.name}</strong>
                        <span style={{"color": "#666"}}>{" " + hit.mana_cost + " · " + hit.type_line}</span>
                        <div style={{"color": "#444", "fontSize": "0.9rem", "whiteSpace": "pre-line"}}>{hit.text}</div>
                    </li>
                    for hit in hits
                ]}
            </ul>
            <h2>Export</h2>
            <p>
                <select aria-label="Export format" value={exportFormat} onChange={lambda e: ChangeEvent { exportFormat = e.target.value; }}>
                    <option value="mtgdeck1">mtgdeck/1</option>
                    <option value="mtgjson">MTGJSON Deck JSON</option>
                    <option value="text">Plain text</option>
                    <option value="arena">MTGA/MTGO</option>
                    <option value="moxfield">Moxfield</option>
                </select>
                <button onClick={lambda _e: MouseEvent { runExport(); }}>Export</button>
            </p>
            <textarea readOnly={True} aria-label="Exported deck" value={exportText} style={{"width": "100%", "height": "8rem"}} />

            <h2>Import</h2>
            <p>
                <select aria-label="Import format" value={importFormat} onChange={lambda e: ChangeEvent { importFormat = e.target.value; }}>
                    <option value="mtgdeck1">mtgdeck/1</option>
                    <option value="text">Plain text</option>
                    <option value="arena">MTGA/MTGO</option>
                    <option value="moxfield">Moxfield</option>
                </select>
            </p>
            <textarea
                aria-label="Deck list to import"
                value={importText}
                onChange={lambda e: ChangeEvent { importText = e.target.value; }}
                style={{"width": "100%", "height": "8rem"}}
            />
            <button onClick={lambda _e: MouseEvent { runImport(); }}>Import</button>
            {<div role="status">
                <strong>Lines that didn't resolve</strong>
                <ul>{[<li key={line}>{line}</li> for line in unresolved]}</ul>
            </div> if unresolved else None}
        </section>;
}
