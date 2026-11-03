from dataclasses import dataclass, field
from typing import Protocol


@dataclass
class ParsedEntry:
    raw_name: str
    count: int
    zone: str = "main"
    oracle_id: str = ""
    role: str = ""
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
    role: str = ""
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
