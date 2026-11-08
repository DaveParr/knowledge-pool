"""One deck: legality, mana, its cards by zone, card search and export.

Laid out like the MCP Apps views Claude shows in chat: the card tables follow
ui/deck_table.html, and ManaPanel, CardSearch and ExportPanel are the web twins
of the mana, search and export apps (#67, #68, #69).
"""

import "./deck_detail.css";
import from .export_panel { ExportPanel }
import from .mana_panel { ManaPanel }
import from .card_search { CardSearch }
import from .mana_cost { ManaCost }

sv import from decks {
    DeckView, DeckCard, FormatInfo, DeckAnalysis, GetDeck, SetDeckFormat, SetCardCount, RemoveCard,
    AnalyzeDeck, list_formats
}
sv import from legality { Violation }
sv import from mana { ManaProfile }

"""Zones in display order, with their headings."""
glob ZONES: list[tuple[str, str]] = [
    ("commander", "Commander"),
    ("companion", "Companion"),
    ("main", "Main deck"),
    ("sideboard", "Sideboard"),
    ("maybeboard", "Maybeboard")
];

def:pub DeckDetail(deckId: str, importNotes: list[str], onBack: Callable[[], None]) -> JsxElement {
    has deck: DeckView | None = None,
        analysis: DeckAnalysis | None = None,
        formats: list[FormatInfo] = [];

    can with entry {
        loadDeck();
    }

    async def loadDeck -> None;
    async def refreshAnalysis -> None;
    async def setCount(oracleId: str, zone: str, value: str) -> None;
    async def removeCard(oracleId: str, zone: str) -> None;
    async def setFormat(value: str) -> None;

    def back(_e: MouseEvent) {
        onBack();
    }

    def changed(view: DeckView) {
        deck = view;
        refreshAnalysis();
    }

    if deck is None {
        return <p className="empty">Loading deck...</p>;
    }

    return
        <section>
            <button className="quiet dd-back" onClick={back}>← Decks</button>
            <div className="dd-head">
                <h1>{deck.name}</h1>
                <ExportPanel deckId={deckId} deckName={deck.name}/>
            </div>
            <p className="meta">
                <select
                    aria-label="Format"
                    value={deck.format}
                    onChange={lambda e: ChangeEvent { setFormat(e.target.value); }}
                >
                    {[<option key={f.name} value={f.name}>{f.label}</option> for f in formats]}
                </select>
                {" · " + str(deck.main_total) + " main · " + str(deck.sideboard_total) + " sideboard"}
            </p>
            {<div role="status" className="status warn">
                <strong>Lines that didn't resolve</strong>
                <ul>
                    {[<li key={str(i)}>{line}</li> for (i, line) in enumerate(importNotes)]}
                </ul>
            </div> if importNotes else None}
            <div role="status" className={"status ok" if deck.legal else "status bad"}>
                <strong>{"Legal" if deck.legal else "Not legal"}</strong>
                {<ul>
                    {[<li key={str(i)}>{v.message}</li> for (i, v) in enumerate(deck.violations)]}
                </ul> if deck.violations else None}
            </div>

            <ManaPanel analysis={analysis} mainTotal={deck.main_total}/>

            {if len(deck.cards) == 0 {
                <p className="empty">This deck has no cards yet. Search below to add some.</p>
            }}
            {for (zone, title) in ZONES {
                rows = [c for c in deck.cards if c.zone == zone];
                if len(rows) > 0 {
                    <div key={zone}>
                        <h2>{title + " (" + str(sum([c.count for c in rows])) + ")"}</h2>
                        <table className="dd-cards">
                            <colgroup>
                                <col className="dd-c-n"/><col/><col className="dd-c-cost"/><col className="dd-c-type"/><col className="dd-c-tags"/><col className="dd-c-x"/>
                            </colgroup>
                            <thead>
                                <tr><th>#</th><th>Card</th><th>Cost</th><th>Type</th><th>Tags</th><th/></tr>
                            </thead>
                            <tbody>
                                {for line in rows {
                                    <tr key={line.zone + line.oracle_id}>
                                        <td>
                                            <input
                                                type="number"
                                                min="0"
                                                className="dd-count"
                                                aria-label={"Count of " + line.name + " in " + line.zone}
                                                value={str(line.count)}
                                                onChange={lambda e: ChangeEvent { setCount(line.oracle_id, line.zone, e.target.value); }}
                                            />
                                        </td>
                                        <td className="dd-card">
                                            {<details>
                                                <summary>{line.name}</summary>
                                                <div className="dd-tip">{line.text}</div>
                                            </details> if line.text else line.name}
                                        </td>
                                        <td className="dd-cost"><ManaCost cost={line.mana_cost}/></td>
                                        <td className="dd-type">{line.type_line}</td>
                                        <td><div className="dd-tags">{[<span key={t} className="pill">{t}</span> for t in line.oracle_tags]}</div></td>
                                        <td>
                                            <button
                                                className="quiet dd-remove"
                                                aria-label={"Remove " + line.name + " from " + line.zone}
                                                title="Remove"
                                                onClick={lambda _e: MouseEvent { removeCard(line.oracle_id, line.zone); }}
                                            >
                                                ✕
                                            </button>
                                        </td>
                                    </tr>
                                }}
                            </tbody>
                        </table>
                    </div>
                }
            }}

            <CardSearch deckId={deckId} cards={deck.cards} onChanged={changed}/>
        </section>;
}
