"""Export one deck: pick a format, see the text, copy or download it.

The web twin of the export MCP app (#69, ui/mockups/export.html). Defaults to
MTGA/MTGO; changing format exports again. The Export button toggles the panel,
which opens below the button's row.
"""

import "./export_panel.css";
import from .walker_failure { failureMessage }

import from deck_io { DeckExport, ExportResult, ExportFormatInfo, export_formats }

glob DEFAULT_EXPORT: str = "arena";

def:pub ExportPanel(deckId: str, deckName: str) -> JsxElement {
    has open: bool = False,
        format: str = DEFAULT_EXPORT,
        content: str = "",
        error: str = "",
        status: str = "",
        choices: list[ExportFormatInfo] = [];

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
    for choice in choices {
        if choice.key == format {
            label = choice.label;
            lossless = choice.lossless;
            ext = choice.ext;
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
                    {for choice in choices {
                        <button
                            key={choice.key}
                            className="ex-format"
                            aria-pressed={choice.key == format}
                            onClick={lambda (_e: MouseEvent) { load(choice.key); }}
                        >
                            {choice.label}
                            <span className="ex-sub">{"lossless" if choice.lossless else "lossy"}</span>
                        </button>
                    }}
                </div>
                {<div className="status ok ex-note">Lossless: this re-imports with every zone, role, tag, lock and reason.</div>
                    if lossless else
                <div className="status warn ex-note">{"Lossy: " + label + " keeps card names and counts for the main deck and sideboard only. It drops other zones, roles, tags, locks and reasons."}</div>}
                {<p className="error" role="alert">{error}</p> if error else None}
                <textarea readOnly={True} aria-label={"Exported " + deckName} value={content} rows={10}/>
                <div className="ex-bar">
                    <button className="primary" onClick={lambda (_e: MouseEvent) { copy(); }}>Copy</button>
                    <button onClick={saveFile}>{"Download ." + ext}</button>
                    <span className="ex-done" role="status">{status}</span>
                    <span className="ex-size">{str(lines) + " lines · " + str(len(content)) + " characters" if content else ""}</span>
                </div>
            </section> if open else None}
        </div>;
}
