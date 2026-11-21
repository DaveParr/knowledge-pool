from dataclasses import dataclass

from deckformats.base import DeckFormat, ExportDeck, ExportEntry, ParsedDeck, ParsedEntry
from deckformats.linelist import LineListFormat
from deckformats.mtgdeck1 import Mtgdeck1Format
from deckformats.mtgjson import MtgjsonFormat


@dataclass(frozen=True)
class ExportFormat:
    """One deck list format the app offers: its key, label, whether a round trip
    keeps everything (lossless), the file extension it downloads as, and the
    DeckFormat that reads and writes it."""

    key: str
    label: str
    lossless: bool
    ext: str
    impl: DeckFormat


# The one place a format is defined, in the order the export views list them.
# Every export choice (the connector, its export view, the web page) reads this.
EXPORT_FORMATS: list[ExportFormat] = [
    ExportFormat("arena", "MTGA/MTGO", False, "txt", LineListFormat(deck_header="Deck", strip_set_suffix=True)),
    ExportFormat("moxfield", "Moxfield", False, "txt", LineListFormat(strip_set_suffix=True)),
    ExportFormat("text", "Plain text", False, "txt", LineListFormat()),
    ExportFormat("mtgdeck1", "mtgdeck/1", True, "json", Mtgdeck1Format()),
    ExportFormat("mtgjson", "MTGJSON", True, "json", MtgjsonFormat()),
]

FORMATS: dict[str, DeckFormat] = {f.key: f.impl for f in EXPORT_FORMATS}


def export_format_choices() -> list[dict[str, str | bool]]:
    """The export formats as plain choices: key, label, lossless, ext."""
    return [{"key": f.key, "label": f.label, "lossless": f.lossless, "ext": f.ext} for f in EXPORT_FORMATS]


def get_format(name: str) -> DeckFormat:
    try:
        return FORMATS[name]
    except KeyError:
        raise ValueError(f"Unknown deck format: {name}. Use one of: {', '.join(sorted(FORMATS))}.") from None
