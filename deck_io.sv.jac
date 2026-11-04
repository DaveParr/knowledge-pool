"""Deck import and export. Each format is a strategy looked up by name from
deckformats.FORMATS: the walkers below depend only on the DeckFormat
protocol, never on a specific format's parsing or rendering code.
"""

import from deckformats { get_format, ExportEntry, ExportDeck, ParsedEntry }
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
`unresolved` and never added; an entry in an unknown zone is listed as
"<name> (invalid zone: <zone>)". The same card listed more than once in a
zone (e.g. two printings) is summed. If the text can't be parsed at all, or
nothing in it resolves, the deck is left exactly as it was."""
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
        } except ValueError as err {
            report ImportResult(deck=deck_view(here), unresolved=[str(err)]);
            disengage;
        }

        # Resolve pass: nothing on the deck changes yet. Each resolved entry
        # is copied with its resolved oracle id.
        unresolved: list[str] = [*parsed.unparsed];
        resolved: list[ParsedEntry] = [];
        for entry in parsed.entries {
            if entry.zone not in DECK_ZONES {
                unresolved.append(f"{entry.raw_name} (invalid zone: {entry.zone})");
                continue;
            }
            oid = "";
            if entry.oracle_id and catalog_get_card(entry.oracle_id) is not None {
                oid = entry.oracle_id;
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
            resolved.append(ParsedEntry(
                raw_name=entry.raw_name, count=entry.count, zone=entry.zone, oracle_id=oid,
                roles=entry.roles, tags=entry.tags, locked=entry.locked, reason=entry.reason
            ));
        }

        # Aggregate: counts for the same card in the same zone are summed;
        # roles/tags/locked/reason come from the last occurrence in the input.
        groups: dict[tuple[str, str], ParsedEntry] = {};
        for entry in resolved {
            key = (entry.oracle_id, entry.zone);
            if key in groups {
                entry.count += groups[key].count;
            }
            groups[key] = entry;
        }

        # Write pass: never empty a deck when the input had content but none
        # of it resolved (a bad paste or the wrong format selected).
        if groups or not (parsed.entries or parsed.unparsed) {
            for (e, c) in holdings(here) {
                del e;
            }
            for g in groups.values() {
                set_card_entry(here, g.oracle_id, g.zone, g.count, g.roles, g.tags, g.locked, g.reason);
            }
        }
        report ImportResult(deck=deck_view(here), unresolved=unresolved);
    }
}
