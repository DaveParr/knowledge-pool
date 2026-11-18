"""Handlers for the export panel."""

impl ExportPanel.load(fmt: str) -> None {
    format = fmt;
    status = "";
    result = root spawn DeckExport(deck_id=deckId, format=fmt);
    why = failureMessage(result.reports);
    error = why;
    if why {
        content = "";
        return;
    }
    content = (result.reports[0] as ExportResult).content;
}

impl ExportPanel.copy -> None {
    try {
        await navigator.clipboard.writeText(content);  # jac:ignore[E1032]
        status = "Copied";
    } except Exception {
        # The browser refused: select the text so the user can copy it by hand.
        box: any = document.querySelector("textarea[aria-label='Exported " + deckName + "']");  # jac:ignore[E1032,W1037]
        if box {
            box.focus();  # jac:ignore[E1032]
            box.select();  # jac:ignore[E1032]
        }
        status = "Selected. Press Ctrl+C (Cmd+C) to copy.";
    }
}

impl ExportPanel.saveFile(_e: MouseEvent) -> None {
    ext = "txt";
    for (k, _l, _ll, x) in EXPORT_FORMATS {
        if k == format {
            ext = x;
        }
    }
    blob = new(Blob, [content], {"type": "text/plain"});  # jac:ignore[E1053,W1051,W2001]
    link: any = document.createElement("a");  # jac:ignore[E1032,W1037]
    link.href = URL.createObjectURL(blob);  # jac:ignore[E1032,W1051]
    stem = deckName.strip().lower().replace(" ", "-") or "deck";
    link.setAttribute("download", stem + "." + ext);  # jac:ignore[E1032]
    link.click();  # jac:ignore[E1032]
}
