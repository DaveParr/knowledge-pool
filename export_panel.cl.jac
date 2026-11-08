"""Export one deck: pick a format, see the text, copy or download it.

The web twin of the export MCP app (#69, ui/mockups/export.html). Defaults to
MTGA/MTGO; changing format exports again. The Export button toggles the panel,
which opens below the button's row.
"""

import "./export_panel.css";
sv import from deck_io { DeckExport }

"""Export formats: key, label, lossless, file extension."""
glob EXPORT_FORMATS: list[tuple[str, str, bool, str]] = [
    ("arena", "MTGA/MTGO", False, "txt"),
    ("moxfield", "Moxfield", False, "txt"),
    ("text", "Plain text", False, "txt"),
    ("mtgdeck1", "mtgdeck/1", True, "json"),
    ("mtgjson", "MTGJSON", True, "json")
];

glob DEFAULT_EXPORT: str = "arena";

def:pub ExportPanel(deckId: str, deckName: str) -> JsxElement {
    has open: bool = False,
        format: str = DEFAULT_EXPORT,
        content: str = "",
        failed: bool = False,
        status: str = "";

    async def load(fmt: str) -> None;
    async def copy -> None;
    def saveFile(_e: MouseEvent) -> None;

    def toggle(_e: MouseEvent) {
        nowOpen = not open;
        open = nowOpen;
        if nowOpen {
            load(format);
        }
    }

    label = "";
    lossless = False;
    ext = "txt";
    for (k, l, ll, x) in EXPORT_FORMATS {
        if k == format {
            label = l;
            lossless = ll;
            ext = x;
        }
    }
    lines = len(content.split(chr(10))) if content else 0;

    return
        <div className="ex-export">
            <button
                className="ex-toggle"
                aria-label={"Export " + deckName}
                aria-expanded={open}
                onClick={toggle}
            >
                {"Export ▴" if open else "Export ▾"}
            </button>
            {<section className="ex-panel" aria-label={"Export " + deckName}>
                <div className="ex-formats" role="group" aria-label="Export format">
                    {for (k, l, ll, _x) in EXPORT_FORMATS {
                        <button
                            key={k}
                            className="ex-format"
                            aria-pressed={k == format}
                            onClick={lambda _e: MouseEvent { load(k); }}
                        >
                            {l}
                            <span className="ex-sub">{"lossless" if ll else "lossy"}</span>
                        </button>
                    }}
                </div>
                {<div className="status ok ex-note">Lossless: this re-imports with every zone, role, tag, lock and reason.</div>
                    if lossless else
                <div className="status warn ex-note">{"Lossy: " + label + " keeps card names and counts for the main deck and sideboard only. It drops other zones, roles, tags, locks and reasons."}</div>}
                {<p className="error" role="alert">Export failed.</p> if failed else None}
                <textarea readOnly={True} aria-label={"Exported " + deckName} value={content} rows={10}/>
                <div className="ex-bar">
                    <button className="primary" onClick={lambda _e: MouseEvent { copy(); }}>Copy</button>
                    <button onClick={saveFile}>{"Download ." + ext}</button>
                    <span className="ex-done" role="status">{status}</span>
                    <span className="ex-size">{str(lines) + " lines · " + str(len(content)) + " characters" if content else ""}</span>
                </div>
            </section> if open else None}
        </div>;
}
