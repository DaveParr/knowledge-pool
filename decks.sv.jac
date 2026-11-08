"""Decks - server side.

Each deck is a `Deck` node hung off `root`, so it persists across restarts in
`.jac/data`. The walkers are `:pub`: this is a local, single-user app, so every
caller shares one graph and nobody has to log in.
"""

import from datetime { datetime, timezone }
import from cards { Card, card_node, is_land }
import from legality { Format, Violation, Entry, FORMAT_LABELS, format_node, check_entries }
import from mana { ManaLine, ManaProfile, mana_profile }

"""One change to how many copies of a card a zone of a deck holds, with the
reason given for it. Every holdings change writes one (see change_holding)."""
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

"""Every zone a deck can hold cards in (the mtgdeck/1 zones), in display
order. The one list of zones: every holdings change and every import checks
against it. Legality looks only at main and sideboard (see ValidateDeck)."""
glob ZONES: list[str] = ["commander", "companion", "main", "sideboard", "maybeboard"];

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
        report new_deck(here, name, self.format);
    }
}

"""Create a deck under `owner` (the root) and return it. Callers check the name and format."""
def new_deck(owner: Root, name: str, format: str) -> Deck {
    deck = Deck(name=name, created_at=datetime.now(timezone.utc).isoformat(), format=format);
    owner ++> deck;
    return deck;
}

"""Report every deck, oldest first."""
walker:pub ListDecks {
    has reports: list[list[Deck]] = [];

    can collect with Root entry {
        decks = sorted([here-->[?:Deck]], key=lambda d: Deck : d.created_at);
        report decks;
    }
}

"""A deck holds `count` copies of a card in one zone (one of ZONES).
roles/tags/locked/reason are mtgdeck/1 entry metadata. Change these edges only
through change_holding / replace_holdings."""
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

"""A deck, its cards (sorted by zone then name), whether it is legal in its
format, and its main-deck mana analysis (mana profile and curve). Every walker
that reports a deck reports this whole view, so one request per edit gives a
client the full picture."""
obj DeckView {
    has id: str,
        name: str,
        format: str,
        mana: ManaProfile,
        curve: ManaCurve,
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
    lines.sort(key=lambda l: DeckCard : (ZONES.index(l.zone), l.name));
    check = deck spawn ValidateDeck();
    return DeckView(
        id=jid(deck),
        name=deck.name,
        format=deck.format,
        mana=mana_profile(main_deck_mana_lines(deck)),
        curve=mana_curve(deck),
        cards=lines,
        main_total=sum([l.count for l in lines if l.zone == "main"]),
        sideboard_total=sum([l.count for l in lines if l.zone == "sideboard"]),
        legal=len(check.violations) == 0,
        violations=check.violations,
        history=deck.history[-20:]
    );
}

# ---- Deck holdings -------------------------------------------------------
# The one way a deck's cards change. change_holding (one card, one zone) and
# replace_holdings (the whole list) share one edit rule, apply_holding: it
# checks the zone, count and reason, materialises the Card node, writes the
# Holds edge and its entry metadata, and logs a ChangeNote. Walkers never
# touch Holds edges themselves.

"""One card line for replace_holdings: `count` copies in `zone`, plus the
mtgdeck/1 entry metadata. `reason` is why the card is in the deck, not why
the deck changed."""
obj HoldingEntry {
    has oracle_id: str,
        zone: str,
        count: int,
        roles: list[str] = [],
        tags: list[str] = [],
        locked: bool = False,
        reason: str = "";
}

"""The Holds edge for this card in this zone, and the card, if the deck holds it."""
def held(deck: Deck, oid: str, zone: str) -> tuple[Holds, Card] | None {
    for (e, c) in holdings(deck) {
        if c.oracle_id == oid and e.zone == zone {
            return (e, c);
        }
    }
    return None;
}

"""Why a change would be refused before looking at the card, or "" if it is allowed."""
def holding_refusal(zone: str, count: int, reason: str, add: bool) -> str {
    if not reason.strip() {
        return "every change needs a reason.";
    }
    if zone not in ZONES {
        return f"zone must be one of: {', '.join(ZONES)}.";
    }
    least = 1 if add else 0;
    if not isinstance(count, int) or isinstance(count, bool) or count < least {
        return f"count must be a whole number, {least} or more.";
    }
    return "";
}

"""The edit rule. Sets (or with `add`, raises) the count of `oid` in `zone`;
0 removes it. With `line`, the entry metadata is overwritten from it; without,
existing metadata is kept. Logs a ChangeNote when the count changes. Returns ""
when applied, else why it was refused (and nothing is written)."""
def apply_holding(deck: Deck, oid: str, zone: str, count: int, reason: str, add: bool, line: HoldingEntry | None) -> str {
    refusal = holding_refusal(zone, count, reason, add);
    if refusal {
        return refusal;
    }
    found = held(deck, oid, zone);
    before = found[0].count if found is not None else 0;
    after = before + count if add else count;
    name = oid;
    if found is None {
        if after == 0 {
            return "";
        }
        card = card_node(root, oid);
        if card is None {
            return f"{oid} is not a known oracle id.";
        }
        meta = line if line is not None else HoldingEntry(oracle_id=oid, zone=zone, count=after);
        deck +>:Holds(
            count=after, zone=zone, roles=meta.roles, tags=meta.tags, locked=meta.locked, reason=meta.reason
        ):+> card;
        name = card.name;
    } else {
        (hold, held_card) = found;
        name = held_card.name;
        if after == 0 {
            del hold;
        } else {
            hold.count = after;
            if line is not None {
                hold.roles = line.roles;
                hold.tags = line.tags;
                hold.locked = line.locked;
                hold.reason = line.reason;
            }
        }
    }
    if after != before {
        deck.history.append(
            ChangeNote(
                at=datetime.now(timezone.utc).isoformat(),
                oracle_id=oid,
                name=name,
                zone=zone,
                before=before,
                after=after,
                reason=reason.strip()
            )
        );
    }
    return "";
}

"""Set how many copies of a card one zone of a deck holds (with `add`, add
that many on top), and log the change with `reason` in the deck's history.
0 removes the card from the zone. The entry's roles, tags, lock and reason
are kept. A change that leaves the count as it was is applied but not logged.
Returns "" when applied, else why it was refused; a refused change writes
nothing."""
def change_holding(deck: Deck, oracle_id: str, zone: str, count: int, reason: str, add: bool = False) -> str {
    return apply_holding(deck, oracle_id, zone, count, reason, add, None);
}

"""Make the deck hold exactly `entries`, with their entry metadata, and
nothing else. Each count that changes is logged with `reason`. Returns one
message per refused entry ("<oracle_id> (<zone>): <why>"); refused entries
are not held, and the rest of the list still replaces the deck's holdings."""
def replace_holdings(deck: Deck, entries: list[HoldingEntry], reason: str) -> list[str] {
    refused: list[str] = [];
    kept: set[tuple[str, str]] = set();
    for en in entries {
        why = apply_holding(deck, en.oracle_id, en.zone, en.count, reason, False, en);
        if why {
            refused.append(f"{en.oracle_id} ({en.zone}): {why}");
        } else {
            kept.add((en.oracle_id, en.zone));
        }
    }
    for (e, c) in holdings(deck) {
        if (c.oracle_id, e.zone) not in kept {
            apply_holding(deck, c.oracle_id, e.zone, 0, reason, False, None);
        }
    }
    return refused;
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

"""The reason logged for a change made in the web app, which asks for none."""
glob WEB_EDIT_REASON: str = "Edited in the app";

"""Add copies of a card to a zone of a deck (on top of any already there).
Reports nothing if the change is refused (see change_holding)."""
walker:pub AddCard(DeckAction) {
    has oracle_id: str,
        count: int = 1,
        zone: str = "main";

    can add with Deck entry {
        if change_holding(here, self.oracle_id, self.zone, self.count, WEB_EDIT_REASON, add=True) {
            disengage;
        }
        report deck_view(here);
    }
}

"""Apply a batch of changes, each with a reason, and log each one on the deck.

Each change is {"oracle_id", "count", "zone", "reason"} and sets that card's
count in that zone. Bad changes are skipped and listed in the view's `rejected`.
"""
walker EditDeck(DeckAction) {
    has changes: list[dict] = [];

    can edit with Deck entry {
        rejected: list[str] = [];
        for (i, ch) in enumerate(self.changes) {
            oid = str(ch.get("oracle_id", ""));
            why = change_holding(
                here, oid, str(ch.get("zone", "main")), ch.get("count") as int, str(ch.get("reason", ""))
            );
            if why {
                rejected.append(f"Change {i + 1} ({oid}): {why}");
            }
        }
        view = deck_view(here);
        view.rejected = rejected;
        report view;
    }
}

"""Set how many copies of a card a zone holds. Zero removes the card from that
zone. Reports nothing if the change is refused (see change_holding)."""
walker:pub SetCardCount(DeckAction) {
    has oracle_id: str,
        count: int,
        zone: str = "main";

    can set_count with Deck entry {
        if change_holding(here, self.oracle_id, self.zone, self.count, WEB_EDIT_REASON) {
            disengage;
        }
        report deck_view(here);
    }
}

"""Take a card out of one zone of a deck. Reports nothing for an unknown zone."""
walker:pub RemoveCard(DeckAction) {
    has oracle_id: str,
        zone: str = "main";

    can remove with Deck entry {
        if change_holding(here, self.oracle_id, self.zone, 0, WEB_EDIT_REASON) {
            disengage;
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
