"""Mana for one deck: totals, the mana curve and coloured pips vs sources.

The web twin of the mana analysis MCP app (#67, ui/mockups/mana_analysis.html):
same layout, both fed by AnalyzeDeck. Main deck only.
"""

import "./mana_panel.css";
sv import from decks { DeckAnalysis }

glob COLOUR_NAMES: dict[str, str] = {
    "W": "White", "U": "Blue", "B": "Black", "R": "Red", "G": "Green"
};

def pct(n: int, top: int) -> str {
    return str(round(100 * n / top) if top > 0 else 0) + "%";
}

def:pub ManaPanel(analysis: DeckAnalysis | None, mainTotal: int) -> JsxElement {
    has showTable: bool = False;

    if analysis is None {
        return <p className="empty">Loading mana...</p>;
    }

    buckets = analysis.curve.buckets;
    nonLand = 0;
    topCount = 1;
    for (_mv, n) in buckets.items() {
        nonLand += n;
        topCount = max(topCount, n);
    }
    mana = analysis.mana;
    used = [c for c in ["W", "U", "B", "R", "G"] if mana.pips[c] > 0 or mana.sources[c] > 0];
    topPS = 1;
    for c in used {
        topPS = max(topPS, mana.pips[c], mana.sources[c]);
    }

    return
        <section aria-label="Mana">
            <div className="mp-tiles">
                <div className="mp-tile">
                    <div className="mp-k">Lands</div>
                    <div className="mp-v">{analysis.mana.land_count}</div>
                    <div className="mp-s">{pct(mana.land_count, mainTotal) + " of main"}</div>
                </div>
                <div className="mp-tile">
                    <div className="mp-k">Non-land spells</div>
                    <div className="mp-v">{nonLand}</div>
                    <div className="mp-s">in the curve below</div>
                </div>
                <div className="mp-tile">
                    <div className="mp-k">Average mana value</div>
                    <div className="mp-v">{f"{analysis.curve.average_mv:.2f}"}</div>
                    <div className="mp-s">non-land only</div>
                </div>
            </div>

            <h2>Mana curve</h2>
            <div className="mp-curve" role="img" aria-label="Mana curve: non-land cards by mana value">
                {for (mv, n) in buckets.items() {
                    <div key={mv} className="mp-col" data-tip={"Mana value " + mv + ": " + str(n) + (" card" if n == 1 else " cards")}>
                        {<span className="mp-n">{n}</span> if n > 0 else None}
                        <div className="mp-bar" style={{"height": pct(n, topCount)}}/>
                    </div>
                }}
            </div>
            <div className="mp-axis">
                {for (mv, _n) in buckets.items() {
                    <span key={mv}>{mv}</span>
                }}
            </div>
            <div className="mp-axis-title">Mana value</div>

            <h2>Coloured pips vs sources</h2>
            {if len(used) == 0 {
                <p className="empty">No coloured mana in the main deck yet.</p>
            } else {
                <div className="mp-legend">
                    <span><span className="mp-key mp-key-pips"/>Pips (spell demand)</span>
                    <span><span className="mp-key mp-key-sources"/>Sources (lands and mana producers)</span>
                </div>
                for c in used {
                    <div key={c} className="mp-colour">
                        <div className="mp-name">{COLOUR_NAMES[c]}<small>{c}</small></div>
                        <div className="mp-pair">
                            <div className="mp-hrow">
                                <div className="mp-hbar mp-hbar-pips" style={{"width": pct(mana.pips[c], topPS)}}/>
                                <span className="mp-hv">{mana.pips[c]}</span>
                            </div>
                            <div className="mp-hrow">
                                <div className="mp-hbar mp-hbar-sources" style={{"width": pct(mana.sources[c], topPS)}}/>
                                <span className="mp-hv">{mana.sources[c]}</span>
                            </div>
                        </div>
                    </div>
                }
            }}

            <button
                type="button"
                className="quiet mp-show-table"
                aria-expanded={showTable}
                onClick={lambda _e: MouseEvent { showTable = not showTable; }}
            >
                {"Hide table" if showTable else "Show as table"}
            </button>
            {<div className="mp-tables">
                <table>
                    <thead><tr><th>Mana value</th><th className="mp-num">Cards</th></tr></thead>
                    <tbody>
                        {for (mv, n) in buckets.items() {
                            <tr key={mv}><td>{mv}</td><td className="mp-num">{n}</td></tr>
                        }}
                    </tbody>
                </table>
                <table>
                    <thead><tr><th>Colour</th><th className="mp-num">Pips</th><th className="mp-num">Sources</th></tr></thead>
                    <tbody>
                        {for c in used {
                            <tr key={c}>
                                <td>{COLOUR_NAMES[c]}</td>
                                <td className="mp-num">{mana.pips[c]}</td>
                                <td className="mp-num">{mana.sources[c]}</td>
                            </tr>
                        }}
                    </tbody>
                </table>
            </div> if showTable else None}
        </section>;
}
