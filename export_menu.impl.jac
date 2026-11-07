"""Handlers for the export button."""

impl ExportMenu.exportAs(format: str, label: str) -> None {
    open = False;
    status = "";
    result = root spawn DeckExport(deck_id=deckId, format=format);
    if not result.reports {
        status = "Export failed";
        return;
    }
    text = result.reports[0].content;
    copied = False;
    try {
        await navigator.clipboard.writeText(text);  # jac:ignore[E1032]
        copied = True;
    } except Exception {
        copied = False;
    }
    if copied {
        status = "Copied " + label;
    } else {
        manualText = text;
    }
}
