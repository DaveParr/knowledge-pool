import json

from deckformats.base import ExportDeck, ParsedDeck, ParsedEntry


class Mtgdeck1Format:
    def render(self, deck: ExportDeck) -> str:
        zones: dict[str, list[dict]] = {}
        for e in deck.entries:
            entry: dict = {"name": e.name, "oracleId": e.oracle_id, "count": e.count}
            if e.roles:
                entry["roles"] = e.roles
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
        """Parse an mtgdeck/1 document.

        A structurally broken document (not JSON, not an object, `zones` not
        an object, a zone not a list) raises ValueError. A single bad entry
        is skipped and described in `unparsed`, so the rest still imports.
        """
        try:
            doc = json.loads(text)
        except json.JSONDecodeError:
            raise ValueError("Not a valid mtgdeck/1 document: the text is not JSON.") from None
        if not isinstance(doc, dict):
            raise ValueError("Not a valid mtgdeck/1 document: expected a JSON object.")
        zones = doc.get("zones", {})
        if not isinstance(zones, dict):
            raise ValueError("Not a valid mtgdeck/1 document: `zones` must be an object.")

        parsed = ParsedDeck(name=str(doc.get("name", "")), format=str(doc.get("format", "")))
        for zone, zone_entries in zones.items():
            if not isinstance(zone_entries, list):
                raise ValueError(f"Not a valid mtgdeck/1 document: zone `{zone}` must be a list.")
            for entry in zone_entries:
                problem = _entry_problem(entry)
                if problem:
                    name = entry.get("name") if isinstance(entry, dict) else None
                    label = name if isinstance(name, str) and name else "<unnamed>"
                    parsed.unparsed.append(f"{label} ({problem})")
                    continue
                parsed.entries.append(
                    ParsedEntry(
                        raw_name=entry["name"],
                        count=entry["count"],
                        zone=zone,
                        oracle_id=entry.get("oracleId", ""),
                        roles=entry.get("roles", []),
                        tags=entry.get("tags", []),
                        locked=entry.get("locked", False),
                        reason=entry.get("reason", ""),
                    )
                )

        return parsed


def _is_str_list(value) -> bool:
    return isinstance(value, list) and all(isinstance(v, str) for v in value)


def _entry_problem(entry) -> str:
    """Why an entry can't be imported, or "" if it can. Mirrors the schema:
    a non-empty string name, an integer count >= 1, string-list roles/tags."""
    if not isinstance(entry, dict):
        return "invalid entry"
    if not isinstance(entry.get("name"), str) or not entry["name"]:
        return "invalid name"
    count = entry.get("count")
    if isinstance(count, bool) or not isinstance(count, int) or count < 1:
        return "invalid count"
    if not isinstance(entry.get("oracleId", ""), str):
        return "invalid oracleId"
    if not _is_str_list(entry.get("roles", [])):
        return "invalid roles"
    if not _is_str_list(entry.get("tags", [])):
        return "invalid tags"
    if not isinstance(entry.get("locked", False), bool):
        return "invalid locked"
    if not isinstance(entry.get("reason", ""), str):
        return "invalid reason"
    return ""
