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
