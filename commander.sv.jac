"""Commander-specific helpers: which zones count for what, and who may lead.
The rules that use them live in `legality`."""

import from card_lines { CardLine }

"""Zones counted for deck size and singleton."""
glob DECK_ZONES: list[str] = ["commander", "main"];

"""Zones whose cards must be legal in Commander."""
glob CHECKED_ZONES: list[str] = ["commander", "companion", "main"];

"""The lines in the commander zone."""
def commanders(lines: list[CardLine]) -> list[CardLine] {
    return [l for l in lines if l.zone == "commander"];
}

"""Whether MTGJSON says this card can be your commander."""
def can_lead(line: CardLine) -> bool {
    return line.leadership.get("commander", False);
}

"""The five colours, in WUBRG order."""
glob COLOURS: list[str] = ["W", "U", "B", "R", "G"];

"""The union of the lines' colour identities, in WUBRG order."""
def identity(lines: list[CardLine]) -> list[str] {
    have: set[str] = set();
    for l in lines {
        have |= set(l.colour_identity);
    }
    return [c for c in COLOURS if c in have];
}

"""A colour identity as text: "colourless", or the letters ("R", "UR", "WUBG")."""
def identity_label(colours: list[str]) -> str {
    if not colours {
        return "colourless";
    }
    return "".join([c for c in COLOURS if c in colours]);
}

"""The commanders' names, joined with "and"."""
def commander_names(cmdrs: list[CardLine]) -> str {
    return " and ".join([c.name for c in cmdrs]);
}
