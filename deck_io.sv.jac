"""Deck import and export. Each format is a strategy looked up by name from
deckformats.FORMATS: the walkers below depend only on the DeckFormat
protocol, never on a specific format's parsing or rendering code.
"""

import from deckformats { get_format, ExportEntry, ExportDeck }
import from catalog.store { find_by_name, get_card as catalog_get_card }
import from decks { Deck, DeckAction, DeckView, DECK_ZONES, holdings, deck_view, set_card_entry }

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
    has format: str = "mtgdeck1",
        reports: list[ExportResult] = [];

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
                    roles=e.roles, tags=e.tags, locked=e.locked, reason=e.reason
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

"""Import a deck list, replacing the deck's current holdings entirely.
Lines or entries that don't resolve to a known card are listed in
`unresolved` and never added."""
walker:pub DeckImport(DeckAction) {
    has format: str = "mtgdeck1",
        text: str = "",
        reports: list[ImportResult] = [];

    can do_import with Deck entry {
        try {
            fmt = get_format(self.format);
        } except ValueError {
            disengage;
        }
        try {
            parsed = fmt.parse(self.text);
        } except NotImplementedError {
            disengage;
        }
        for (e, c) in holdings(here) {
            del e;
        }
        unresolved: list[str] = [*parsed.unparsed];
        for entry in parsed.entries {
            if entry.zone not in DECK_ZONES {
                unresolved.append(entry.raw_name);
                continue;
            }
            oid = "";
            if entry.oracle_id {
                if catalog_get_card(entry.oracle_id) is not None {
                    oid = entry.oracle_id;
                }
            } else {
                found = find_by_name(entry.raw_name);
                if found is not None {
                    oid = found["oracle_id"] as str;
                }
            }
            if not oid {
                unresolved.append(entry.raw_name);
                continue;
            }
            set_card_entry(here, oid, entry.zone, entry.count, entry.roles, entry.tags, entry.locked, entry.reason);
        }
        report ImportResult(deck=deck_view(here), unresolved=unresolved);
    }
}
