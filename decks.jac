"""Decks - server side.

Each deck is a `Deck` node hung off `root`, so it persists across restarts in
the graph. The walkers the web page calls are `:protect`, never `:pub`: the page
needs them as endpoints to compile, Jac's server refuses a call without a Jac
token, and no Jac token is issued. The front door (`front_door.jac`) runs those
calls itself, as the caller, through the runner.
"""

import from datetime { datetime, timezone }
import from cards { Card, card_node }
import from card_lines { CardLine, main_deck }
import from legality { Violation, FORMAT_LABELS, format_node, check_lines, unknown_format }
import from commander { GameChangers, game_changers }
import from mana { ManaProfile, ManaCurve, mana_profile, mana_curve }
import from walker_errors { WalkerError }
import from json_object { JsonObject }

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
against it. Constructed legality looks only at main and sideboard (see
legality.LEGALITY_ZONES); Commander also counts the commander and companion zones."""
glob ZONES: list[str] = ["commander", "companion", "main", "sideboard", "maybeboard"];

"""Create a deck and report it. A blank name or an unknown format creates
nothing and reports a WalkerError (blank-name, unknown-format)."""
walker:protect CreateDeck {
    has name: str,
        format: str = "standard",
        reports: list[Deck | WalkerError] = [];

    can create with Root entry {
        name = self.name.strip();
        if not name {
            report WalkerError(code="blank-name", message="A deck needs a name.");
            disengage;
        }
        if self.format not in FORMAT_LABELS {
            report unknown_format(self.format);
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
walker:protect ListDecks {
    has reports: list[list[Deck]] = [];

    can collect with Root entry {
        decks = sorted([here-->[?:Deck]], key=lambda (d: Deck) { return d.created_at; });
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
        cards: list[CardLine] = [],
        main_total: int = 0,
        sideboard_total: int = 0,
        legal: bool = False,
        violations: list[Violation] = [],
        history: list[ChangeNote] = [],
        rejected: list[str] = [],
        game_changers: GameChangers | None = None;
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

"""A card line for `count` copies of catalogue card `c` in `zone`, with the
holding's roles, tags, lock and reason."""
def card_line(
    c: Card, zone: str, count: int, roles: list[str] | None = None, tags: list[str] | None = None, locked: bool = False, reason: str = ""
) -> CardLine {
    return CardLine(
        oracle_id=c.oracle_id,
        name=c.name,
        zone=zone,
        count=count,
        mana_cost=c.mana_cost,
        mana_value=c.mana_value,
        type_line=c.type_line,
        text=c.text,
        legal=c.legal,
        oracle_tags=c.oracle_tags,
        produced_mana=c.produced_mana,
        power=c.power,
        toughness=c.toughness,
        loyalty=c.loyalty,
        defense=c.defense,
        keywords=c.keywords,
        faces=c.faces,
        colour_identity=c.colour_identity,
        leadership=c.leadership,
        game_changer=c.game_changer,
        roles=roles or [],
        tags=tags or [],
        locked=locked,
        reason=reason
    );
}

"""The deck's card lines, sorted by zone (ZONES order) then name: the one read
model every analysis and export works from (see card_lines.jac)."""
def card_lines(deck: Deck) -> list[CardLine] {
    lines: list[CardLine] = [
        card_line(c, e.zone, e.count, e.roles, e.tags, e.locked, e.reason) for (e, c) in holdings(deck)
    ];
    lines.sort(key=lambda (l: CardLine) { return (ZONES.index(l.zone), l.name); });
    return lines;
}

"""What a deck's lines break in its format. An unknown format is itself a violation."""
def deck_violations(deck: Deck, lines: list[CardLine]) -> list[Violation] {
    fmt = format_node(root.shared, deck.format);
    if fmt is None {
        return [Violation(rule="unknown-format", message=f"Unknown format: {deck.format}.")];
    }
    return check_lines(lines, fmt);
}

def deck_view(deck: Deck) -> DeckView {
    lines = card_lines(deck);
    violations = deck_violations(deck, lines);
    return DeckView(
        id=jid(deck),
        name=deck.name,
        format=deck.format,
        mana=mana_profile(lines),
        curve=mana_curve(lines),
        cards=lines,
        main_total=sum([l.count for l in main_deck(lines)]),
        sideboard_total=sum([l.count for l in lines if l.zone == "sideboard"]),
        legal=len(violations) == 0,
        violations=violations,
        history=deck.history[-20:],
        game_changers=game_changers(lines) if deck.format == "commander" else None
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
        card = card_node(root.shared, oid);
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
            # Delete this one edge. A typed-edge delete (`del [edge deck ->:Holds:->]`)
            # does nothing on current Jac, and would take the card's other zones too.
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

"""The error for a holdings change that change_holding refused, with its reason."""
def refused_change(why: str) -> WalkerError {
    return WalkerError(code="refused-change", message=f"Change refused: {why}");
}

"""The caller's own deck with id `deck_id`: one that hangs off the caller's
root. None for an id that names no deck, or names another user's deck even
when Jac would let the caller read it."""
def own_deck(deck_id: str) -> Deck | None {
    try {
        target = jobj(deck_id);
    } except ValueError {
        return None;
    }
    if not isinstance(target, Deck) {
        return None;
    }
    if jid(target) not in [jid(d) for d in [root-->[?:Deck]]] {
        return None;
    }
    return target;
}

"""Base for walkers that act on one deck. An id that names no deck of the
caller's is handled here, once: the walker reports a no-such-deck
WalkerError and stops. Another user's deck answers the same way."""
walker DeckAction {
    has deck_id: str,
        reports: list[DeckView | WalkerError] = [];

    can locate with Root entry {
        deck = own_deck(self.deck_id);
        if deck is None {
            report WalkerError(code="no-such-deck", message=f"No deck with id {self.deck_id}.");
            disengage;
        }
        visit [deck];
    }
}

"""Report a deck, its cards and its legality."""
walker:protect GetDeck(DeckAction) {
    can show with Deck entry {
        report deck_view(here);
    }
}

"""Change the format a deck is checked against."""
walker:protect SetDeckFormat(DeckAction) {
    has format: str;

    can set_format with Deck entry {
        if self.format not in FORMAT_LABELS {
            report unknown_format(self.format);
            disengage;
        }
        here.format = self.format;
        report deck_view(here);
    }
}

"""The reason logged for a change made in the web app, which asks for none."""
glob WEB_EDIT_REASON: str = "Edited in the app";

"""Add copies of a card to a zone of a deck (on top of any already there).
A refused change (see change_holding) reports a refused-change WalkerError."""
walker:protect AddCard(DeckAction) {
    has oracle_id: str,
        count: int = 1,
        zone: str = "main";

    can add with Deck entry {
        why = change_holding(here, self.oracle_id, self.zone, self.count, WEB_EDIT_REASON, add=True);
        if why {
            report refused_change(why);
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
    has changes: list[JsonObject] = [];

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
zone. A refused change (see change_holding) reports a refused-change WalkerError."""
walker:protect SetCardCount(DeckAction) {
    has oracle_id: str,
        count: int,
        zone: str = "main";

    can set_count with Deck entry {
        why = change_holding(here, self.oracle_id, self.zone, self.count, WEB_EDIT_REASON);
        if why {
            report refused_change(why);
            disengage;
        }
        report deck_view(here);
    }
}

"""Take a card out of one zone of a deck. An unknown zone reports a refused-change WalkerError."""
walker:protect RemoveCard(DeckAction) {
    has oracle_id: str,
        zone: str = "main";

    can remove with Deck entry {
        why = change_holding(here, self.oracle_id, self.zone, 0, WEB_EDIT_REASON);
        if why {
            report refused_change(why);
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

def:protect list_formats -> list[FormatInfo] {
    return [FormatInfo(name=k, label=v) for (k, v) in FORMAT_LABELS.items()];
}
