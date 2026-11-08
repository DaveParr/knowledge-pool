"""Card lines - the one read model every deck analysis works from.

A card line is one card in one zone of a deck: its count and entry metadata,
plus the catalogue facts about the card. `decks.card_lines` builds them from
the graph; legality, the mana profile and the curve are pure functions over a
deck's lines, so each can be tested without a graph. The one definition of a
land (`CardLine.is_land`) and of the main deck (`main_deck`) live here.
"""

"""One card in one zone of a deck, as every analyser and client sees it."""
obj CardLine {
    has oracle_id: str,
        name: str,
        zone: str,
        count: int,
        mana_cost: str = "",
        mana_value: float = 0.0,
        type_line: str = "",
        text: str = "",
        legal: dict[str, str] = {},
        oracle_tags: list[str] = [],
        produced_mana: list[str] = [],
        roles: list[str] = [],
        tags: list[str] = [],
        locked: bool = False,
        reason: str = "";

    """True when the card's front face is a land. A double-faced card that is
    a spell on the front and a land on the back (Valakut Awakening) is a
    spell: it is cast from hand at its front face's mana value. Dryad Arbor
    (Land Creature) is a land."""
    def is_land() -> bool {
        front = self.type_line.split(" // ")[0];
        return "Land" in front.split("—")[0].split();
    }
}

"""The lines in the main deck: the cards the game starts with."""
def main_deck(lines: list[CardLine]) -> list[CardLine] {
    return [l for l in lines if l.zone == "main"];
}
