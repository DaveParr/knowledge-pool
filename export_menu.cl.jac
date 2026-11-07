"""Compact export button for one deck. Picking a format copies the export to
the clipboard; when the browser refuses, the text is shown to copy by hand."""

sv import from deck_io { DeckExport }

glob EXPORT_FORMATS: list[tuple[str, str]] = [
    ("mtgdeck1", "mtgdeck/1"),
    ("mtgjson", "MTGJSON Deck JSON"),
    ("text", "Plain text"),
    ("arena", "MTGA/MTGO"),
    ("moxfield", "Moxfield")
];

def:pub ExportMenu(deckId: str, deckName: str) -> JsxElement {
    has open: bool = False,
        status: str = "",
        manualText: str = "";

    async def exportAs(format: str, label: str) -> None;

    return
        <span style={{"position": "relative", "display": "inline-block"}}>
            <button
                aria-label={"Export " + deckName}
                aria-haspopup="menu"
                aria-expanded={open}
                onClick={lambda _e: MouseEvent { open = not open; manualText = ""; status = ""; }}
                style={{"fontSize": "0.85rem", "padding": "0.15rem 0.5rem"}}
            >
                {"Export ▾"}
            </button>
            {<span role="status" style={{"marginLeft": "0.5rem", "fontSize": "0.85rem", "color": "#1b5e20"}}>{status}</span> if status else None}
            {<div
                role="menu"
                style={{
                    "position": "absolute", "right": "0", "zIndex": "10", "marginTop": "0.25rem",
                    "background": "#fff", "border": "1px solid #ccc", "borderRadius": "6px",
                    "boxShadow": "0 2px 8px rgba(0,0,0,0.15)", "minWidth": "12rem"
                }}
            >
                {[
                    <button
                        key={fmt}
                        role="menuitem"
                        onClick={lambda _e: MouseEvent { exportAs(fmt, label); }}
                        style={{
                            "display": "block", "width": "100%", "textAlign": "left",
                            "padding": "0.4rem 0.75rem", "border": "none", "background": "none", "cursor": "pointer"
                        }}
                    >
                        {label}
                    </button>
                    for (fmt, label) in EXPORT_FORMATS
                ]}
            </div> if open else None}
            {<div
                style={{
                    "position": "absolute", "right": "0", "zIndex": "10", "marginTop": "0.25rem",
                    "background": "#fff", "border": "1px solid #ccc", "borderRadius": "6px",
                    "padding": "0.5rem", "width": "22rem"
                }}
            >
                <p style={{"margin": "0 0 0.25rem", "fontSize": "0.85rem"}}>Couldn't copy automatically. Select and copy:</p>
                <textarea
                    readOnly={True}
                    aria-label={"Exported " + deckName}
                    value={manualText}
                    style={{"width": "100%", "height": "8rem"}}
                />
                <button onClick={lambda _e: MouseEvent { manualText = ""; }}>Close</button>
            </div> if manualText else None}
        </span>;
}
