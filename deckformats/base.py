from dataclasses import dataclass, field
from typing import Protocol


@dataclass
class ParsedEntry:
    raw_name: str
    count: int
    zone: str = "main"
    oracle_id: str = ""
    roles: list[str] = field(default_factory=list)
    tags: list[str] = field(default_factory=list)
    locked: bool = False
    reason: str = ""


@dataclass
class ParsedDeck:
    name: str = ""
    format: str = ""
    entries: list[ParsedEntry] = field(default_factory=list)
    unparsed: list[str] = field(default_factory=list)


@dataclass
class ExportEntry:
    oracle_id: str
    name: str
    count: int
    zone: str
    roles: list[str] = field(default_factory=list)
    tags: list[str] = field(default_factory=list)
    locked: bool = False
    reason: str = ""


@dataclass
class ExportDeck:
    name: str
    format: str
    entries: list[ExportEntry]


class DeckFormat(Protocol):
    def parse(self, text: str) -> ParsedDeck: ...

    def render(self, deck: ExportDeck) -> str: ...


def basic_entry_problem(entry) -> str:
    """Why a JSON deck entry can't be imported, or "" if it can: it must be an
    object with a non-empty string name and an integer count >= 1."""
    if not isinstance(entry, dict):
        return "invalid entry"
    if not isinstance(entry.get("name"), str) or not entry["name"]:
        return "invalid name"
    count = entry.get("count")
    if isinstance(count, bool) or not isinstance(count, int) or count < 1:
        return "invalid count"
    return ""


def unparsed_note(entry, problem: str) -> str:
    """How a skipped entry is listed in `ParsedDeck.unparsed`: its name (or
    "<unnamed>") and the problem."""
    name = entry.get("name") if isinstance(entry, dict) else None
    label = name if isinstance(name, str) and name else "<unnamed>"
    return f"{label} ({problem})"
