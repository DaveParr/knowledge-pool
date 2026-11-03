from deckformats.base import DeckFormat, ExportDeck, ExportEntry, ParsedDeck, ParsedEntry
from deckformats.mtgdeck1 import Mtgdeck1Format

DECK_ZONES = ("commander", "companion", "main", "sideboard", "maybeboard")

FORMATS: dict[str, DeckFormat] = {
    "mtgdeck1": Mtgdeck1Format(),
}


def get_format(name: str) -> DeckFormat:
    try:
        return FORMATS[name]
    except KeyError:
        raise ValueError(f"Unknown deck format: {name}. Use one of: {', '.join(sorted(FORMATS))}.") from None
