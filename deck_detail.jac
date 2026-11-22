"""One deck: legality, mana, its cards by zone, card search and export.

Laid out like the MCP Apps views Claude shows in chat: the card lists follow
ui/deck_table.html, and ManaPanel, CardSearch and ExportPanel are the web twins
of the mana, search and export apps (#67, #68, #69).
"""

import "./deck_detail.css";
import from .export_panel { ExportPanel }
import from .mana_panel { ManaPanel }
import from .card_search { AddCards }
import from .mana_cost { ManaCost }
import from .walker_failure { failureMessage, REFUSED_LINE }

import from decks {
    ChangeNote, DeckView, FormatInfo, GetDeck, CopyOtherDeck, EditDeck, list_formats
}
import from zones { ZONES, ZONE_TITLES }
import from edit_reason { WEB_EDIT_REASON }
import from legality { Violation }
import from commander { GameChangers }
import from mana { ManaProfile }
import from card_lines { CardLine }
import from walker_errors { WalkerError }

"""A play format's label ("Standard"), or the name itself when it is not listed."""
def:pub formatName(name: str, formats: list[FormatInfo]) -> str {
    for f in formats {
        if f.name == name {
            return f.label;
        }
    }
    return name;
}

"""One card line's key: a card can be in more than one zone."""
def rowKey(line: CardLine) -> str {
    return line.zone + ":" + line.oracle_id;
}

"""The Game Changers line: "Game Changers: 2 — Chrome Mox, Rhystic Study"."""
def gameChangersLine(gc: GameChangers) -> str {
    line = "Game Changers: " + str(gc.count);
    if gc.count > 0 {
        line = line + " — " + gc.cards[0];
        for name in gc.cards[1:] {
            line = line + ", " + name;
        }
    }
    return line;
}

"""Power/toughness as "2/2", or "" for a card or face without them."""
def powerToughness(power: str, toughness: str) -> str {
    return power + "/" + toughness if power or toughness else "";
}

"""A face's stat badges: loyalty and defence, and P/T when `withPT` (the
card's row already shows the front face's P/T)."""
def FaceStats(power: str, toughness: str, loyalty: str, defense: str, withPT: bool) -> JsxElement {
    pt = powerToughness(power, toughness) if withPT else "";
    if not (pt or loyalty or defense) {
        return <></>;
    }
    return
        <div>
            {<span className="dd-stats" title="Power/toughness">{pt}</span> if pt else None}
            {<span className="dd-stats">{"Loyalty " + loyalty}</span> if loyalty else None}
            {<span className="dd-stats">{"Defence " + defense}</span> if defense else None}
        </div>;
}

"""A card's expanded details: rules text per face (with each face's name, cost,
type and stats), keywords, this deck's notes for the card, then Scryfall tags
last, in quieter text. Follows the expanded rows of ui/deck_table.html."""
def:pub CardDetails(line: CardLine) -> JsxElement {
    notes = len(line.roles) > 0 or line.locked or line.reason != "";
    return
        <div className="dd-body">
            {if len(line.faces) > 0 {
                for (i, face) in enumerate(line.faces) {
                    <div key={str(i)} className="dd-face">
                        <h3>
                            {face.name}
                            <span className="dd-ft">
                                {<ManaCost cost={face.mana_cost}/> if face.mana_cost else None}
                                {(" · " if face.mana_cost else "") + face.type_line}
                            </span>
                        </h3>
                        {<p className="dd-rules">{face.text}</p> if face.text else None}
                        <FaceStats
                            power={face.power}
                            toughness={face.toughness}
                            loyalty={face.loyalty}
                            defense={face.defense}
                            withPT={i > 0}
                        />
                    </div>
                }
            } elif line.text or line.loyalty or line.defense {
                <div key="rules" className="dd-face">
                    {<p className="dd-rules">{line.text}</p> if line.text else None}
                    <FaceStats power="" toughness="" loyalty={line.loyalty} defense={line.defense} withPT={False}/>
                </div>
            }}
            {<dl>
                {if len(line.keywords) > 0 {
                    <dt key="kw">Keywords</dt>
                    <dd key="kw-v" className="dd-pills">{[<span key={k} className="pill dd-kw">{k}</span> for k in line.keywords]}</dd>
                }}
                {if notes {
                    <dt key="deck">In this deck</dt>
                    <dd key="deck-v" className="dd-pills">
                        {[<span key={r} className="pill">{r}</span> for r in line.roles]}
                        {<span className="pill">locked</span> if line.locked else None}
                        {<span>{"“" + line.reason + "”"}</span> if line.reason else None}
                    </dd>
                }}
                {if len(line.oracle_tags) > 0 {
                    <dt key="tags" className="dd-quiet">Scryfall tags</dt>
                    <dd key="tags-v" className="dd-tags">{[<span key={t}>{(" · " if i > 0 else "") + t}</span> for (i, t) in enumerate(line.oracle_tags)]}</dd>
                }}
            </dl> if len(line.keywords) > 0 or notes or len(line.oracle_tags) > 0 else None}
        </div>;
}

"""One history line: the change made, and why."""
def historyLine(note: ChangeNote) -> str {
    what = note.reason;
    if note.name {
        what = note.name + " (" + note.zone + "): " + str(note.before) + " → " + str(note.after) + (" — " + note.reason if note.reason else "");
    }
    return note.at[:10] + "  " + what;
}

"""A deck. `readOnly` is another user's deck: every control that changes it is
left out, and Copy is offered instead; `onCopied` gets the new deck's id."""
def:pub DeckDetail(
    deckId: str, importNotes: list[str], readOnly: bool, onCopied: Callable[[str], None], onBack: Callable[[], None]
) -> JsxElement {
    has deck: DeckView | None = None,
        error: str = "",
        formats: list[FormatInfo] = [],
        opened: dict[str, bool] = {},
        renaming: bool = False,
        draft: str = "";

    can with entry {
        loadDeck();
    }

    async def loadDeck -> None;
    async def setCount(oracleId: str, zone: str, value: str) -> None;
    async def removeCard(oracleId: str, zone: str) -> None;
    async def setFormat(value: str) -> None;
    async def copyDeck -> None;
    async def renameDeck -> None;

    def startRename(_e: MouseEvent) {
        draft = deck.name if deck else "";
        renaming = True;
    }

    def cancelRename(_e: MouseEvent) {
        renaming = False;
    }
    """Show a deck walker's view, or the reason it failed (the deck shown stays as it was)."""
    def show(reports: list[DeckView | WalkerError]) -> None;

    def back(_e: MouseEvent) {
        onBack();
    }

    def changed(view: DeckView) {
        deck = view;
    }

    """Remember whether one card's details are open (the user toggled them)."""
    def setOpen(key: str, isOpen: bool) {
        if bool(opened.get(key, False)) != isOpen {
            now: dict[str, bool] = opened.copy();
            now[key] = isOpen;
            opened = now;
        }
    }

    """Expand all / Collapse all for one zone's cards."""
    def openAll(rows: list[CardLine], isOpen: bool) {
        now: dict[str, bool] = opened.copy();
        for line in rows {
            now[rowKey(line)] = isOpen;
        }
        opened = now;
    }

    alert = <p role="alert" className="error">{error}</p> if error else None;
    if deck is None {
        return <section>{alert if error else <p className="empty">Loading deck...</p>}</section>;
    }

    return
        <section>
            <button className="quiet dd-back" onClick={back}>← Decks</button>
            <div className="dd-head">
                {<form className="dd-rename" onSubmit={lambda (e: Event) { e.preventDefault(); renameDeck(); }}>
                    <input
                        aria-label="Deck name"
                        value={draft}
                        autoFocus={True}
                        onChange={lambda (e: ChangeEvent) { draft = e.target.value; }}
                    />
                    <button type="submit" className="primary">Save</button>
                    <button type="button" className="quiet" onClick={cancelRename}>Cancel</button>
                </form> if renaming else <h1>
                    {deck.name}
                    {<button className="quiet dd-rename-btn" aria-label="Rename deck" onClick={startRename}>Rename</button> if not readOnly else None}
                </h1>}
                <span>
                    {<button className="primary dd-copy" onClick={lambda (_e: MouseEvent) { copyDeck(); }}>Copy to my decks</button> if readOnly else None}
                    <ExportPanel deckId={deckId} deckName={deck.name}/>
                </span>
            </div>
            {<p role="status" className="status dd-readonly">
                {"This deck belongs to another user, so you can't change it. Copy it to make your own to change."}
            </p> if readOnly else None}
            <p className="meta">
                {<span className="pill">{formatName(deck.format, formats)}</span> if readOnly else <select
                    aria-label="Format"
                    value={deck.format}
                    onChange={lambda (e: ChangeEvent) { setFormat(e.target.value); }}
                >
                    {[<option key={f.name} value={f.name}>{f.label}</option> for f in formats]}
                </select>}
                {" · " + str(deck.main_total) + " main · " + str(deck.sideboard_total) + " sideboard"}
            </p>
            {alert}
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
                {<div className="dd-gc">
                    <p>{gameChangersLine(deck.game_changers)}</p>
                    <p>{"Bracket hint: " + deck.game_changers.bracket_hint + " (from Game Changers only, not a full bracket rating)"}</p>
                </div> if deck.game_changers else None}
            </div>

            <ManaPanel mana={deck.mana} curve={deck.curve} mainTotal={deck.main_total}/>

            {if len(deck.cards) == 0 {
                <p className="empty">This deck has no cards yet. Search below to add some.</p>
            }}
            {for zone in ZONES {
                title = ZONE_TITLES[zone];
                rows = [c for c in deck.cards if c.zone == zone];
                if len(rows) > 0 {
                    <div key={zone}>
                        <div className="dd-zonehead">
                            <h2>{title + " (" + str(sum([c.count for c in rows])) + ")"}</h2>
                            <span>
                                <button className="quiet dd-all" onClick={lambda (_e: MouseEvent) { openAll(rows, True); }}>Expand all</button>
                                <button className="quiet dd-all" onClick={lambda (_e: MouseEvent) { openAll(rows, False); }}>Collapse all</button>
                            </span>
                        </div>
                        <div className="dd-row dd-colhead" aria-hidden="true">
                            <span>#</span>
                            <div className="dd-line"><span/><span>Card</span><span>Cost</span><span className="dd-type">Type</span><span className="dd-pt">P/T</span></div>
                            <span/>
                        </div>
                        <ul className="dd-cards">
                            {for line in rows {
                                <li key={rowKey(line)} className="dd-row">
                                    {<span className="dd-count" aria-label={"Count of " + line.name + " in " + line.zone}>{str(line.count)}</span> if readOnly else <input
                                        type="number"
                                        min="0"
                                        className="dd-count"
                                        aria-label={"Count of " + line.name + " in " + line.zone}
                                        value={str(line.count)}
                                        onChange={lambda (e: ChangeEvent) { setCount(line.oracle_id, line.zone, e.target.value); }}
                                    />}
                                    <details
                                        open={bool(opened.get(rowKey(line), False))}
                                        onToggle={lambda (e: Event) { setOpen(rowKey(line), e.target.hasAttribute("open")); }}
                                    >
                                        <summary className="dd-line">
                                            <span className="dd-name">{line.name}</span>
                                            <span className="dd-cost"><ManaCost cost={line.mana_cost}/></span>
                                            <span className="dd-type" title={line.type_line}>{line.type_line}</span>
                                            <span className="dd-pt">{powerToughness(line.power, line.toughness)}</span>
                                        </summary>
                                        <CardDetails line={line}/>
                                    </details>
                                    {<span/> if readOnly else <button
                                        className="quiet dd-remove"
                                        aria-label={"Remove " + line.name + " from " + line.zone}
                                        title="Remove"
                                        onClick={lambda (_e: MouseEvent) { removeCard(line.oracle_id, line.zone); }}
                                    >
                                        ✕
                                    </button>}
                                </li>
                            }}
                        </ul>
                    </div>
                }
            }}

            {<AddCards deckId={deckId} format={deck.format} cards={deck.cards} onChanged={changed}/> if not readOnly else None}

            <h2>History</h2>
            {<p className="empty">No changes yet.</p> if len(deck.history) == 0 else None}
            <ul className="dd-history" aria-label="History">
                {[<li key={str(i)}>{historyLine(note)}</li> for (i, note) in enumerate(deck.history)]}
            </ul>
        </section>;
}
