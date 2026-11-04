import re
from dataclasses import dataclass

from deckformats.base import ExportDeck, ParsedDeck, ParsedEntry

LINE_RE = re.compile(r"^(\d+)x?\s+(.+)$")
SET_SUFFIX_RE = re.compile(r"\s*\([A-Za-z0-9]{2,5}\)\s*[A-Za-z0-9\-★]*$")


@dataclass
class LineListFormat:
    deck_header: str | None = None
    sideboard_header: str | None = "Sideboard"
    strip_set_suffix: bool = False

    def render(self, deck: ExportDeck) -> str:
        main = [e for e in deck.entries if e.zone == "main"]
        sideboard = [e for e in deck.entries if e.zone == "sideboard"]

        lines: list[str] = []
        if self.deck_header:
            lines.append(self.deck_header)
        lines.extend(f"{e.count} {e.name}" for e in main)
        if sideboard:
            lines.append("")
            if self.sideboard_header:
                lines.append(self.sideboard_header)
            lines.extend(f"{e.count} {e.name}" for e in sideboard)

        return "\n".join(lines) + "\n"

    def parse(self, text: str) -> ParsedDeck:
        # Built-in commander/companion headers, plus this instance's own.
        header_zones = {"commander": "commander", "companion": "companion"}
        header_zones.update({
            _header_key(header): zone
            for header, zone in {self.deck_header: "main", self.sideboard_header: "sideboard"}.items()
            if header is not None
        })

        parsed = ParsedDeck()
        current_zone = "main"
        for line in text.splitlines():
            if not line.strip():
                continue
            zone = header_zones.get(_header_key(line))
            if zone is not None:
                current_zone = zone
                continue

            match = LINE_RE.match(line)
            if not match:
                parsed.unparsed.append(line)
                continue

            name = match.group(2).strip()
            if self.strip_set_suffix:
                name = SET_SUFFIX_RE.sub("", name).strip()

            parsed.entries.append(ParsedEntry(raw_name=name, count=int(match.group(1)), zone=current_zone))

        return parsed


def _header_key(line: str) -> str:
    """Normalize a possible header line: "Sideboard:" and "sideboard" match."""
    return line.strip().removesuffix(":").strip().casefold()
