"""Deck import and export. Each format is a strategy looked up by name from
deckformats.FORMATS: the walkers below depend only on the DeckFormat
protocol, never on a specific format's parsing or rendering code.
"""

import from deckformats { get_format, ExportEntry, ExportDeck }
import from catalog.store { find_by_name, get_card as catalog_get_card }
import from decks { Deck, DeckAction, DeckView, holdings, deck_view, set_card_entry }

obj ExportResult {
    has format: str,
        content: str;
}

obj ImportResult {
    has deck: DeckView,
        unresolved: list[str] = [];
}

"""Export a deck in the given format (mtgdeck1, mtgjson, text, arena or
moxfield). Reports nothing for an unknown format or one that does not
support export."""
walker:pub DeckExport(DeckAction) {
    has format: str = "mtgdeck1";

    can export with Deck entry {
        try {
            fmt = get_format(self.format);
        } except ValueError {
            disengage;
        }
        export_deck = ExportDeck(
            name=here.name,
            format=here.format,
            entries=[
                ExportEntry(
                    oracle_id=c.oracle_id, name=c.name, count=e.count, zone=e.zone,
                    role=e.role, tags=e.tags, locked=e.locked, reason=e.reason
                )
                for (e, c) in holdings(here)
            ]
        );
        try {
            content = fmt.render(export_deck);
        } except NotImplementedError {
            disengage;
        }
        report ExportResult(format=self.format, content=content);
    }
}
