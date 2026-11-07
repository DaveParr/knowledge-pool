import json

from deckformats.base import ExportDeck, ParsedDeck

MTGJSON_ZONE_KEYS = {
    "commander": "commander", "companion": "companion", "main": "mainBoard",
    "sideboard": "sideBoard", "maybeboard": "maybeboard",
}


class MtgjsonFormat:
    def render(self, deck: ExportDeck) -> str:
        doc: dict = {"name": deck.name, "code": "", **{key: [] for key in MTGJSON_ZONE_KEYS.values()}}
        for e in deck.entries:
            doc[MTGJSON_ZONE_KEYS[e.zone]].append({"count": e.count, "name": e.name})
        return json.dumps(doc, indent=2)

    def parse(self, text: str) -> ParsedDeck:
        raise NotImplementedError("mtgjson import is not supported")
