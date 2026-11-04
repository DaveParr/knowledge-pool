from deckformats.base import DeckFormat, ExportDeck, ExportEntry, ParsedDeck, ParsedEntry
from deckformats.linelist import LineListFormat
from deckformats.mtgdeck1 import Mtgdeck1Format
from deckformats.mtgjson import MtgjsonFormat

DECK_ZONES = ("commander", "companion", "main", "sideboard", "maybeboard")

FORMATS: dict[str, DeckFormat] = {
    "mtgdeck1": Mtgdeck1Format(),
    "mtgjson": MtgjsonFormat(),
    "text": LineListFormat(),
    "arena": LineListFormat(deck_header="Deck", strip_set_suffix=True),
    "moxfield": LineListFormat(strip_set_suffix=True),
}


def get_format(name: str) -> DeckFormat:
    try:
        return FORMATS[name]
    except KeyError:
        raise ValueError(f"Unknown deck format: {name}. Use one of: {', '.join(sorted(FORMATS))}.") from None
