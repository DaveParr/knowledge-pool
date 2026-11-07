"""Decks - server side.

Each deck is a `Deck` node hung off `root`, so it persists across restarts in
`.jac/data`. The walkers are `:pub`: this is a local, single-user app, so every
caller shares one graph and nobody has to log in.
"""

import from datetime { datetime, timezone }
import from cards { Card, card_node, is_land }
import from legality { Format, Violation, Entry, FORMAT_LABELS, format_node, check_entries }
import from mana { ManaLine, ManaProfile, mana_profile }

"""One change made to a deck through MCP, with the reason given for it."""
obj ChangeNote {
    has at: str,
        oracle_id: str,
        name: str,
        zone: str,
        before: int,
        after: int,
        reason: str;
}

node Deck {
    has name: str,
        created_at: str = "",
        format: str = "standard",
        history: list[ChangeNote] = [];
}

glob ZONES: list[str] = ["main", "sideboard"];

"""All five mtgdeck/1 zones. Additive to ZONES: used by set_card_entry and
later import/export walkers, not by AddCard/SetCardCount/RemoveCard, which
keep governing only the 60-card-format gameplay zones via ZONES."""
glob DECK_ZONES: list[str] = ["commander", "companion", "main", "sideboard", "maybeboard"];

"""Create a deck and report it. A blank name creates nothing and reports nothing."""
walker:pub CreateDeck {
    has name: str,
        format: str = "standard",
        reports: list[Deck] = [];

    can create with Root entry {
        name = self.name.strip();
        if not name or self.format not in FORMAT_LABELS {
            disengage;
        }
        deck = Deck(
            name=name,
            created_at=datetime.now(timezone.utc).isoformat(),
            format=self.format
        );
        here ++> deck;
        report deck;
    }
}

"""Report every deck, oldest first."""
walker:pub ListDecks {
    has reports: list[list[Deck]] = [];

    can collect with Root entry {
        decks = sorted([here-->[?:Deck]], key=lambda d: Deck : d.created_at);
        report decks;
    }
}

"""A deck holds `count` copies of a card in one zone (main or sideboard, or,
via set_card_entry, one of the other mtgdeck/1 zones). roles/tags/locked/reason
are mtgdeck/1 entry metadata, unused by the 60-card-format gameplay walkers."""
edge Holds: Deck --> Card {
    has count: int = 1,
        zone: str = "main",
        roles: list[str] = [],
        tags: list[str] = [],
        locked: bool = False,
        reason: str = "";
}

"""One line of a deck's card list."""
obj DeckCard {
    has oracle_id: str,
        name: str,
        count: int,
        zone: str,
        mana_cost: str,
        type_line: str,
        text: str = "",
        oracle_tags: list[str] = [],
        roles: list[str] = [],
        tags: list[str] = [],
        locked: bool = False,
        reason: str = "";
}

"""A deck, its cards (sorted by zone then name) and whether it is legal in its format."""
obj DeckView {
    has id: str,
        name: str,
        format: str,
        mana: ManaProfile,
        cards: list[DeckCard] = [],
        main_total: int = 0,
        sideboard_total: int = 0,
        legal: bool = False,
        violations: list[Violation] = [],
        history: list[ChangeNote] = [],
        rejected: list[str] = [];
}

"""Every (edge, card) pair a deck holds. A card in both zones has two edges."""
def holdings(deck: Deck) -> list[tuple[Holds, Card]] {
    pairs: list[tuple[Holds, Card]] = [];
    seen: set[str] = set();
    for c in [deck ->:Holds:->] {
        if jid(c) in seen {
            continue;
        }
        seen.add(jid(c));
        for e in [edge deck ->:Holds:-> c] {
            pairs.append((e, c));
        }
    }
    return pairs;
}

"""The deck's main-deck lines, as the mana analyser sees them. The sideboard
is not part of the mana base."""
def main_deck_mana_lines(deck: Deck) -> list[ManaLine] {
    lines: list[ManaLine] = [];
    for (e, c) in holdings(deck) {
        if e.zone != "main" {
            continue;
        }
        lines.append(
            ManaLine(count=e.count, is_land="Land" in c.types, mana_cost=c.mana_cost, produced_mana=c.produced_mana)
        );
    }
    return lines;
}

"""Check a deck against its format's rules. Runs after every edit."""
walker ValidateDeck {
    has violations: list[Violation] = [];

    can check with Deck entry {
        fmt = format_node(root, here.format);
        if fmt is None {
            self.violations = [
                Violation(rule="unknown-format", message=f"Unknown format: {here.format}.")
            ];
            disengage;
        }
        entries: list[Entry] = [];
        for (e, c) in holdings(here) {
            if e.zone not in ["main", "sideboard"] {
                continue;
            }
            entries.append(
                Entry(
                    name=c.name,
                    zone=e.zone,
                    count=e.count,
                    type_line=c.type_line,
                    text=c.text,
                    status=c.legal.get(here.format, "Not legal")
                )
            );
        }
        self.violations = check_entries(entries, fmt);
    }
}

def deck_view(deck: Deck) -> DeckView {
    lines: list[DeckCard] = [];
    for (e, c) in holdings(deck) {
        lines.append(
            DeckCard(
                oracle_id=c.oracle_id,
                name=c.name,
                count=e.count,
                zone=e.zone,
                mana_cost=c.mana_cost,
                type_line=c.type_line,
                text=c.text,
                oracle_tags=c.oracle_tags,
                roles=e.roles,
                tags=e.tags,
                locked=e.locked,
                reason=e.reason
            )
        );
    }
    lines.sort(key=lambda l: DeckCard : (DECK_ZONES.index(l.zone), l.name));
    check = deck spawn ValidateDeck();
    return DeckView(
        id=jid(deck),
        name=deck.name,
        format=deck.format,
        mana=mana_profile(main_deck_mana_lines(deck)),
        cards=lines,
        main_total=sum([l.count for l in lines if l.zone == "main"]),
        sideboard_total=sum([l.count for l in lines if l.zone == "sideboard"]),
        legal=len(check.violations) == 0,
        violations=check.violations,
        history=deck.history[-20:]
    );
}

glob CURVE_BUCKETS: list[str] = ["0", "1", "2", "3", "4", "5", "6", "7+"];

"""Non-land mana-value buckets (0..6, 7+) over a deck's main deck, by card count,
plus the average non-land mana value."""
obj ManaCurve {
    has buckets: dict[str, int] = {},
        average_mv: float = 0.0;
}

def bucket_for(mv: float) -> str {
    n = int(mv);
    return "7+" if n >= 7 else str(max(n, 0));
}

def mana_curve(deck: Deck) -> ManaCurve {
    buckets: dict[str, int] = {b: 0 for b in CURVE_BUCKETS};
    total_mv = 0.0;
    total_count = 0;
    for (e, c) in holdings(deck) {
        if e.zone != "main" or is_land(c) {
            continue;
        }
        buckets[bucket_for(c.mana_value)] += e.count;
        total_mv += c.mana_value * e.count;
        total_count += e.count;
    }
    avg: float = 0.0;
    if total_count > 0 {
        raw: float = total_mv / total_count;
        scaled: float = round(raw * 100);
        avg = scaled / 100.0;
    }
    return ManaCurve(buckets=buckets, average_mv=avg);
}

"""The Holds edge for this card in this zone, if any."""
def holds_edge(deck: Deck, oid: str, zone: str) -> Holds | None {
    for (e, c) in holdings(deck) {
        if c.oracle_id == oid and e.zone == zone {
            return e;
        }
    }
    return None;
}

"""Base for walkers that act on one deck. Reports nothing if the deck id is unknown."""
walker DeckAction {
    has deck_id: str,
        reports: list[DeckView] = [];

    can locate with Root entry {
        try {
            target = jobj(self.deck_id);
        } except ValueError {
            disengage;
        }
        if isinstance(target, Deck) {
            visit [target];
        }
    }
}

"""Report a deck, its cards and its legality."""
walker:pub GetDeck(DeckAction) {
    can show with Deck entry {
        report deck_view(here);
    }
}

"""Analysis of one deck: mana profile and curve. #41 adds card roles here as
it lands."""
obj DeckAnalysis {
    has id: str,
        mana: ManaProfile,
        curve: ManaCurve;
}

"""Report a deck's mana analysis. Reports nothing if the deck id is unknown."""
walker:pub AnalyzeDeck {
    has deck_id: str,
        reports: list[DeckAnalysis] = [];

    can locate with Root entry {
        try {
            target = jobj(self.deck_id);
        } except ValueError {
            disengage;
        }
        if isinstance(target, Deck) {
            visit [target];
        }
    }

    can analyze with Deck entry {
        report DeckAnalysis(
            id=jid(here),
            mana=mana_profile(main_deck_mana_lines(here)),
            curve=mana_curve(here)
        );
    }
}

"""Change the format a deck is checked against."""
walker:pub SetDeckFormat(DeckAction) {
    has format: str;

    can set_format with Deck entry {
        if self.format not in FORMAT_LABELS {
            disengage;
        }
        here.format = self.format;
        report deck_view(here);
    }
}

"""Add copies of a card to a zone of a deck (on top of any already there)."""
walker:pub AddCard(DeckAction) {
    has oracle_id: str,
        count: int = 1,
        zone: str = "main";

    can add with Deck entry {
        if self.count < 1 or self.zone not in ZONES {
            disengage;
        }
        existing = holds_edge(here, self.oracle_id, self.zone);
        if existing is not None {
            existing.count += self.count;
        } else {
            card = card_node(root, self.oracle_id);
            if card is None {
                disengage;
            }
            here +>:Holds(count=self.count, zone=self.zone):+> card;
        }
        report deck_view(here);
    }
}

"""Set a card's count in one zone of a deck (0 removes it). Returns the count
before the change, or None if the card id is unknown."""
def set_card_count(deck: Deck, oid: str, zone: str, count: int) -> int | None {
    existing = holds_edge(deck, oid, zone);
    if existing is None {
        if count == 0 {
            return 0;
        }
        card = card_node(root, oid);
        if card is None {
            return None;
        }
        deck +>:Holds(count=count, zone=zone):+> card;
        return 0;
    }
    before = existing.count;
    if count == 0 {
        del existing;
    } else {
        existing.count = count;
    }
    return before;
}

"""Set a card's full entry (count plus roles, tags, locked and reason) in one
zone. Like set_card_count, but also carries the mtgdeck/1 entry metadata;
used by DeckImport. Always overwrites, never accumulates. Returns the count
before the change, or None if the zone or card id is unknown."""
def set_card_entry(deck: Deck, oid: str, zone: str, count: int, roles: list[str] = [], tags: list[str] = [], locked: bool = False, reason: str = "") -> int | None {
    if zone not in DECK_ZONES {
        return None;
    }
    existing = holds_edge(deck, oid, zone);
    if existing is None {
        card = card_node(root, oid);
        if card is None {
            return None;
        }
        deck +>:Holds(count=count, zone=zone, roles=roles, tags=tags, locked=locked, reason=reason):+> card;
        return 0;
    }
    before = existing.count;
    existing.count = count;
    existing.roles = roles;
    existing.tags = tags;
    existing.locked = locked;
    existing.reason = reason;
    return before;
}

"""Apply a batch of changes, each with a reason, and log each one on the deck.

Each change is {"oracle_id", "count", "zone", "reason"} and sets that card's
count in that zone. Bad changes are skipped and listed in the view's `rejected`.
"""
walker EditDeck(DeckAction) {
    has changes: list[dict] = [];

    can edit with Deck entry {
        rejected: list[str] = [];
        now = datetime.now(timezone.utc).isoformat();
        for (i, ch) in enumerate(self.changes) {
            oid = str(ch.get("oracle_id", ""));
            zone = str(ch.get("zone", "main"));
            reason = str(ch.get("reason", "")).strip();
            raw_count = ch.get("count");
            if not reason {
                rejected.append(f"Change {i + 1} ({oid}): every change needs a reason.");
                continue;
            }
            if zone not in ZONES {
                rejected.append(f"Change {i + 1} ({oid}): zone must be main or sideboard.");
                continue;
            }
            if not isinstance(raw_count, int) or isinstance(raw_count, bool) or raw_count < 0 {
                rejected.append(f"Change {i + 1} ({oid}): count must be a whole number, 0 or more.");
                continue;
            }
            count = raw_count as int;
            before = set_card_count(here, oid, zone, count);
            if before is None {
                rejected.append(f"Change {i + 1}: {oid} is not a known oracle id. Use resolve_names.");
                continue;
            }
            card = card_node(root, oid);
            here.history.append(
                ChangeNote(
                    at=now,
                    oracle_id=oid,
                    name=card.name if card is not None else oid,
                    zone=zone,
                    before=before,
                    after=count,
                    reason=reason
                )
            );
        }
        view = deck_view(here);
        view.rejected = rejected;
        report view;
    }
}

"""Set how many copies of a card a zone holds. Zero removes the card from that zone."""
walker:pub SetCardCount(DeckAction) {
    has oracle_id: str,
        count: int,
        zone: str = "main";

    can set_count with Deck entry {
        if self.count < 0 or self.zone not in ZONES {
            disengage;
        }
        existing = holds_edge(here, self.oracle_id, self.zone);
        if existing is None {
            if self.count == 0 {
                report deck_view(here);
                disengage;
            }
            card = card_node(root, self.oracle_id);
            if card is None {
                disengage;
            }
            here +>:Holds(count=self.count, zone=self.zone):+> card;
        } elif self.count == 0 {
            del existing;
        } else {
            existing.count = self.count;
        }
        report deck_view(here);
    }
}

"""Take a card out of one zone of a deck."""
walker:pub RemoveCard(DeckAction) {
    has oracle_id: str,
        zone: str = "main";

    can remove with Deck entry {
        existing = holds_edge(here, self.oracle_id, self.zone);
        if existing is not None {
            del existing;
        }
        report deck_view(here);
    }
}

"""The formats a deck can be checked against."""
obj FormatInfo {
    has name: str,
        label: str;
}

def:pub list_formats() -> list[FormatInfo] {
    return [FormatInfo(name=k, label=v) for (k, v) in FORMAT_LABELS.items()];
}
