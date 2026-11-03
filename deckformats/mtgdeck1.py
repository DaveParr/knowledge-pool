import json

from deckformats.base import ExportDeck, ParsedDeck, ParsedEntry


class Mtgdeck1Format:
    def render(self, deck: ExportDeck) -> str:
        zones: dict[str, list[dict]] = {}
        for e in deck.entries:
            entry: dict = {"name": e.name, "oracleId": e.oracle_id, "count": e.count}
            if e.role:
                entry["role"] = e.role
            if e.tags:
                entry["tags"] = e.tags
            if e.locked:
                entry["locked"] = e.locked
            if e.reason:
                entry["reason"] = e.reason
            zones.setdefault(e.zone, []).append(entry)

        doc = {
            "schema": "mtgdeck/1",
            "name": deck.name,
            "format": deck.format,
            "zones": zones,
        }
        return json.dumps(doc, indent=2)

    def parse(self, text: str) -> ParsedDeck:
        doc = json.loads(text)
        entries: list[ParsedEntry] = []
        for zone, zone_entries in doc.get("zones", {}).items():
            for entry in zone_entries:
                entries.append(
                    ParsedEntry(
                        raw_name=entry["name"],
                        count=entry["count"],
                        zone=zone,
                        oracle_id=entry.get("oracleId", ""),
                        role=entry.get("role", ""),
                        tags=entry.get("tags", []),
                        locked=entry.get("locked", False),
                        reason=entry.get("reason", ""),
                    )
                )

        return ParsedDeck(
            name=doc.get("name", ""),
            format=doc.get("format", ""),
            entries=entries,
        )
