"""Card lines - the one read model every deck analysis works from.

A card line is one card in one zone of a deck: its count and entry metadata,
plus the catalogue facts about the card. `decks.card_lines` builds them from
the graph; legality, the mana profile and the curve are pure functions over a
deck's lines, so each can be tested without a graph. The one definition of a
land (`CardLine.is_land`) and of the main deck (`main_deck`) live here.
"""

import from zones { PLAYED_ZONES }

"""One face of a multi-face card (double-faced, split, adventure, prepare...),
with its own cost, type line, rules text and stats. A stat the face lacks is
"". Stats are text: MTGJSON gives "*" and "1+*" as well as numbers."""
obj CardFace {
    has name: str,
        mana_cost: str = "",
        type_line: str = "",
        text: str = "",
        power: str = "",
        toughness: str = "",
        loyalty: str = "",
        defense: str = "";
}

"""One card in one zone of a deck, as every analyser and client sees it.
`power`, `toughness`, `loyalty` and `defense` are the front face's ("" when it
has none); `faces` lists every face of a multi-face card, and is empty for a
one-face card. `collection_count` is how many copies of the card the deck
owner's collection holds (filled in by the runner, see `stamp_collection`)."""
obj CardLine {
    has oracle_id: str,
        name: str,
        zone: str,
        count: int,
        collection_count: int = 0,
        mana_cost: str = "",
        mana_value: float = 0.0,
        type_line: str = "",
        text: str = "",
        legal: dict[str, str] = {},
        oracle_tags: list[str] = [],
        produced_mana: list[str] = [],
        power: str = "",
        toughness: str = "",
        loyalty: str = "",
        defense: str = "",
        keywords: list[str] = [],
        faces: list[CardFace] = [],
        colour_identity: list[str] = [],
        leadership: dict[str, bool] = {},
        game_changer: bool = False,
        roles: list[str] = [],
        tags: list[str] = [],
        locked: bool = False,
        reason: str = "";

    """True when the card's front face is a land. A double-faced card that is
    a spell on the front and a land on the back (Valakut Awakening) is a
    spell: it is cast from hand at its front face's mana value. Dryad Arbor
    (Land Creature) is a land."""
    def is_land -> bool {
        front = self.type_line.split(" // ")[0];
        return "Land" in front.split("—")[0].split();
    }
}

"""The cards a deck needs more copies of than its owner's collection holds: per
oracle card, the copies across the played zones (`PLAYED_ZONES`) minus the
line's `collection_count`, never below zero. The deck is measured on its own
against the whole collection."""
def missing_cards(lines: list[CardLine]) -> list[MissingCard] {
    needed: dict[str, int] = {};
    names: dict[str, str] = {};
    held: dict[str, int] = {};
    for l in lines {
        if l.zone in PLAYED_ZONES {
            needed[l.oracle_id] = needed.get(l.oracle_id, 0) + l.count;
            names[l.oracle_id] = l.name;
            held[l.oracle_id] = l.collection_count;
        }
    }
    short = [MissingCard(oracle_id=o, name=names[o], count=n - held[o]) for (o, n) in needed.items() if n > held[o]];
    short.sort(key=lambda (m: MissingCard) { return m.name; });
    return short;
}

"""The lines in the main deck: the cards the game starts with."""
def main_deck(lines: list[CardLine]) -> list[CardLine] {
    return [l for l in lines if l.zone == "main"];
}

"""A card the deck owner's collection is short of: how many more copies the
deck needs (`count`, always 1 or more)."""
obj MissingCard {
    has oracle_id: str,
        name: str,
        count: int;
}
