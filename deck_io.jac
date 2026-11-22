"""Deck import and export. Each format is a strategy looked up by name from
deckformats.FORMATS: the walkers below depend only on the DeckFormat
protocol, never on a specific format's parsing or rendering code.
"""

import from deckformats { DeckFormat, EXPORT_FORMATS, get_format, ExportEntry, ExportDeck, ParsedEntry }
import from cards { find_card }
import from decks { Deck, DeckAction, DeckView, HoldingEntry, ZONES, new_deck, card_lines, deck_view, replace_holdings }
import from legality { FORMAT_LABELS }
import from walker_errors { WalkerError }

obj ExportResult {
    has format: str,
        content: str,
        name: str = "";
}

obj ImportResult {
    has deck: DeckView,
        unresolved: list[str] = [];
}

"""One export format as the web page and the connector's export view offer it."""
obj ExportFormatInfo {
    has key: str,
        label: str,
        lossless: bool,
        ext: str;
}

"""The export formats, in the order they are offered, from the deckformats package."""
def:protect export_formats -> list[ExportFormatInfo] {
    return [ExportFormatInfo(key=f.key, label=f.label, lossless=f.lossless, ext=f.ext) for f in EXPORT_FORMATS];
}

"""The deck list format named `format`, or the unknown-list-format error."""
def list_format(format: str) -> DeckFormat | WalkerError {
    try {
        return get_format(format);
    } except ValueError as err {
        return WalkerError(code="unknown-list-format", message=str(err));
    }
}

"""Export a deck in the given format (mtgdeck1, mtgjson, text, arena or
moxfield). An unknown format reports an unknown-list-format WalkerError, and
one that cannot be exported a no-export one."""
walker:protect DeckExport(DeckAction) {
    has format: str = "mtgdeck1",
        reports: list[ExportResult | WalkerError] = [];

    can export with Deck entry {
        fmt = list_format(self.format);
        if isinstance(fmt, WalkerError) {
            report fmt;
            disengage;
        }
        export_deck = ExportDeck(
            name=here.name,
            format=here.format,
            entries=[
                ExportEntry(
                    oracle_id=l.oracle_id, name=l.name, count=l.count, zone=l.zone,
                    roles=l.roles, tags=l.tags, locked=l.locked, reason=l.reason
                )
                for l in card_lines(here)
            ]
        );
        try {
            content = fmt.render(export_deck);
        } except NotImplementedError {
            report WalkerError(code="no-export", message=f"{self.format} lists can be imported but not exported.");
            disengage;
        }
        report ExportResult(format=self.format, content=content, name=here.name);
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
without touching any deck. Returns a WalkerError for an unknown format
(unknown-list-format) or one that does not support import (no-import). A parse error or a list with no cards comes back as
a single unresolved message. An entry in an unknown zone is listed as
"<name> (invalid zone: <zone>)". The same card listed more than once in a
zone (e.g. two printings) is summed; roles/tags/locked/reason come from the
last occurrence."""
def resolve_list(format: str, text: str) -> ResolvedList | WalkerError {
    fmt = list_format(format);
    if isinstance(fmt, WalkerError) {
        return fmt;
    }
    try {
        parsed = fmt.parse(text);
    } except NotImplementedError {
        return WalkerError(code="no-import", message=f"{format} lists can be exported but not imported.");
    } except ValueError as err {
        return ResolvedList(unresolved=[str(err)]);
    }
    if not (parsed.entries or parsed.unparsed) {
        return ResolvedList(unresolved=["Nothing to import: no cards found."]);
    }

    unresolved: list[str] = [*parsed.unparsed];
    groups: dict[tuple[str, str], ParsedEntry] = {};
    for ent in parsed.entries {
        if ent.zone not in ZONES {
            unresolved.append(f"{ent.raw_name} (invalid zone: {ent.zone})");
            continue;
        }
        found = find_card(ent.oracle_id) or find_card(ent.raw_name);
        if found is None {
            unresolved.append(ent.raw_name);
            continue;
        }
        oid = found["oracle_id"] as str;
        resolved = ParsedEntry(
            raw_name=ent.raw_name, count=ent.count, zone=ent.zone, oracle_id=oid,
            roles=ent.roles, tags=ent.tags, locked=ent.locked, reason=ent.reason
        );
        key = (oid, ent.zone);
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
Every count that changes is logged in the deck's history. A list format
that cannot be imported reports a WalkerError (see resolve_list)."""
walker:protect DeckImport(DeckAction) {
    has format: str = "mtgdeck1",
        text: str = "",
        reports: list[ImportResult | WalkerError] = [];

    can do_import with Deck entry {
        rl = resolve_list(self.format, self.text);
        if isinstance(rl, WalkerError) {
            report rl;
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
list's own name (mtgdeck/1 or MTGJSON), then "Imported deck". The play format is
`play_format` when it names a known format; otherwise the list's own format
(mtgdeck/1, or commander for an MTGJSON Commander Deck) when known, else standard. When nothing in the list
resolves, no deck is created and `deck_id` is empty. An unknown or
import-less list format reports a WalkerError (see resolve_list)."""
walker:protect CreateDeckFromList {
    has name: str = "",
        format: str = "mtgdeck1",
        text: str = "",
        play_format: str = "",
        reports: list[NewDeckResult | WalkerError] = [];

    can create with Root entry {
        rl = resolve_list(self.format, self.text);
        if isinstance(rl, WalkerError) {
            report rl;
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
