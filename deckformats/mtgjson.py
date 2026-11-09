import json

from deckformats.base import ExportDeck, ParsedDeck, ParsedEntry

MTGJSON_ZONE_KEYS = {
    "commander": "commander", "companion": "companion", "main": "mainBoard",
    "sideboard": "sideBoard", "maybeboard": "maybeboard",
}
ZONE_BY_MTGJSON_KEY = {key: zone for zone, key in MTGJSON_ZONE_KEYS.items()}
# MTGJSON deck lists that are not part of a deck we can hold.
SKIPPED_KEYS = ("displayCommander", "tokens", "planes", "schemes")


class MtgjsonFormat:
    def render(self, deck: ExportDeck) -> str:
        doc: dict = {"name": deck.name, "code": "", **{key: [] for key in MTGJSON_ZONE_KEYS.values()}}
        for e in deck.entries:
            doc[MTGJSON_ZONE_KEYS[e.zone]].append({"count": e.count, "name": e.name})
        return json.dumps(doc, indent=2)

    def parse(self, text: str) -> ParsedDeck:
        """Parse an MTGJSON deck file (`{"meta": ..., "data": {Deck}}`) or a bare Deck object.

        `commander`, `mainBoard`, `sideBoard`, `companion` and `maybeboard` become
        zones; each entry carries `identifiers.scryfallOracleId` as its oracle id
        when present. Non-empty `displayCommander`, `tokens`, `planes` and
        `schemes` lists are not imported and are noted in `unparsed`, as is any
        bad entry. The format is "commander" for a "Commander Deck", else "".
        A document that is not JSON, not an object, or has a zone that is not a
        list raises ValueError.
        """
        try:
            doc = json.loads(text)
        except json.JSONDecodeError:
            raise ValueError("Not a valid MTGJSON deck: the text is not JSON.") from None
        if isinstance(doc, dict) and "data" in doc:
            doc = doc["data"]
        if not isinstance(doc, dict):
            raise ValueError("Not a valid MTGJSON deck: expected a JSON object.")

        parsed = ParsedDeck(
            name=str(doc.get("name", "")),
            format="commander" if doc.get("type") == "Commander Deck" else "",
        )
        for key, zone in ZONE_BY_MTGJSON_KEY.items():
            for entry in _zone_list(doc, key):
                problem = _entry_problem(entry)
                if problem:
                    name = entry.get("name") if isinstance(entry, dict) else None
                    label = name if isinstance(name, str) and name else "<unnamed>"
                    parsed.unparsed.append(f"{label} ({problem})")
                    continue
                identifiers = entry.get("identifiers")
                oracle_id = identifiers.get("scryfallOracleId", "") if isinstance(identifiers, dict) else ""
                parsed.entries.append(ParsedEntry(
                    raw_name=entry["name"], count=entry["count"], zone=zone,
                    oracle_id=oracle_id if isinstance(oracle_id, str) else "",
                ))
        for key in SKIPPED_KEYS:
            skipped = _zone_list(doc, key)
            if skipped:
                noun = "entry" if len(skipped) == 1 else "entries"
                parsed.unparsed.append(f"{key} ({len(skipped)} {noun}, not imported)")
        return parsed


def _zone_list(doc: dict, key: str) -> list:
    entries = doc.get(key)
    if entries is None:
        return []
    if not isinstance(entries, list):
        raise ValueError(f"Not a valid MTGJSON deck: `{key}` must be a list.")
    return entries


def _entry_problem(entry) -> str:
    """Why an entry can't be imported, or "" if it can."""
    if not isinstance(entry, dict):
        return "invalid entry"
    if not isinstance(entry.get("name"), str) or not entry["name"]:
        return "invalid name"
    count = entry.get("count")
    if isinstance(count, bool) or not isinstance(count, int) or count < 1:
        return "invalid count"
    return ""
