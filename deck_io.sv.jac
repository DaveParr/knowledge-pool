"""Deck import and export. Each format is a strategy looked up by name from
deckformats.FORMATS: the walkers below depend only on the DeckFormat
protocol, never on a specific format's parsing or rendering code.
"""

import from deckformats { get_format, ExportEntry, ExportDeck, ParsedEntry }
import from cards { find_card }
import from decks { Deck, DeckAction, DeckView, HoldingEntry, ZONES, new_deck, holdings, deck_view, replace_holdings }
import from legality { FORMAT_LABELS }

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

"""A parsed deck list with every entry resolved against the catalogue.
`entries` holds one entry per (card, zone) with counts summed; `unresolved`
lists the lines or entries that could not be used."""
obj ResolvedList {
    has name: str = "",
        format: str = "",
        entries: list[ParsedEntry] = [],
        unresolved: list[str] = [];
}

"""Parse `text` in the named format and resolve each entry to a catalogue card,
without touching any deck. Returns None for an unknown format or one that
does not support import. A parse error or a list with no cards comes back as
a single unresolved message. An entry in an unknown zone is listed as
"<name> (invalid zone: <zone>)". The same card listed more than once in a
zone (e.g. two printings) is summed; roles/tags/locked/reason come from the
last occurrence."""
def resolve_list(format: str, text: str) -> ResolvedList | None {
    try {
        fmt = get_format(format);
    } except ValueError {
        return None;
    }
    try {
        parsed = fmt.parse(text);
    } except NotImplementedError {
        return None;
    } except ValueError as err {
        return ResolvedList(unresolved=[str(err)]);
    }
    if not (parsed.entries or parsed.unparsed) {
        return ResolvedList(unresolved=["Nothing to import: no cards found."]);
    }

    unresolved: list[str] = [*parsed.unparsed];
    groups: dict[tuple[str, str], ParsedEntry] = {};
    for entry in parsed.entries {
        if entry.zone not in ZONES {
            unresolved.append(f"{entry.raw_name} (invalid zone: {entry.zone})");
            continue;
        }
        found = find_card(entry.oracle_id) or find_card(entry.raw_name);
        if found is None {
            unresolved.append(entry.raw_name);
            continue;
        }
        oid = found["oracle_id"] as str;
        resolved = ParsedEntry(
            raw_name=entry.raw_name, count=entry.count, zone=entry.zone, oracle_id=oid,
            roles=entry.roles, tags=entry.tags, locked=entry.locked, reason=entry.reason
        );
        key = (oid, entry.zone);
        if key in groups {
            resolved.count += groups[key].count;
        }
        groups[key] = resolved;
    }
    return ResolvedList(
        name=parsed.name, format=parsed.format,
        entries=list(groups.values()), unresolved=unresolved
    );
}

"""A resolved list's entries as the deck holdings they become."""
def holding_entries(rl: ResolvedList) -> list[HoldingEntry] {
    return [
        HoldingEntry(
            oracle_id=g.oracle_id, zone=g.zone, count=g.count,
            roles=g.roles, tags=g.tags, locked=g.locked, reason=g.reason
        )
        for g in rl.entries
    ];
}

"""Import a deck list, replacing the deck's current holdings entirely.
Lines or entries that don't resolve are listed in `unresolved` and never
added (see resolve_list). If the text can't be parsed at all, has no cards
in it, or nothing in it resolves, the deck is left exactly as it was.
Every count that changes is logged in the deck's history."""
walker:pub DeckImport(DeckAction) {
    has format: str = "mtgdeck1",
        text: str = "",
        reports: list[ImportResult] = [];

    can do_import with Deck entry {
        rl = resolve_list(self.format, self.text);
        if rl is None {
            disengage;
        }
        # Never empty a deck when none of the input resolved (a bad paste or
        # the wrong format selected).
        unresolved = rl.unresolved;
        if rl.entries {
            unresolved = unresolved + replace_holdings(here, holding_entries(rl), f"Imported from a {self.format} list");
        }
        report ImportResult(deck=deck_view(here), unresolved=unresolved);
    }
}

obj NewDeckResult {
    has deck_id: str = "",
        unresolved: list[str] = [];
}

"""Create a new deck filled from a pasted list. A blank name falls back to the
list's own name (mtgdeck/1), then "Imported deck". The play format is
`play_format` when it names a known format; otherwise the list's own format
(mtgdeck/1) when known, else standard. When nothing in the list
resolves, no deck is created and `deck_id` is empty. Reports nothing for an
unknown or import-less list format."""
walker:pub CreateDeckFromList {
    has name: str = "",
        format: str = "mtgdeck1",
        text: str = "",
        play_format: str = "",
        reports: list[NewDeckResult] = [];

    can create with Root entry {
        rl = resolve_list(self.format, self.text);
        if rl is None {
            disengage;
        }
        if not rl.entries {
            report NewDeckResult(unresolved=rl.unresolved);
            disengage;
        }
        name = self.name.strip() or rl.name.strip() or "Imported deck";
        play_format = "standard";
        if self.play_format in FORMAT_LABELS {
            play_format = self.play_format;
        } elif rl.format in FORMAT_LABELS {
            play_format = rl.format;
        }
        deck = new_deck(here, name, play_format);
        refused = replace_holdings(deck, holding_entries(rl), f"Created from a {self.format} list");
        report NewDeckResult(deck_id=jid(deck), unresolved=rl.unresolved + refused);
    }
}
