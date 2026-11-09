"""MTGJSON precons for `seed.jac`: where the deck list and deck files come
from, which decks are candidates for each play format, and how one is picked.

MTGJSON deck files have a `type` (Commander Deck, Challenger Deck, ...) but no
play format, so DECK_TYPES says which type seeds which format. Brawl,
Archenemy, Planechase and the beginner products are left out: we have no
rules for them.
"""

from __future__ import annotations

import json
import random
import time
import urllib.request
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path

from catalog.ingest import USER_AGENT

DECK_LIST_URL = "https://mtgjson.com/api/v5/DeckList.json"
DECK_URL = "https://mtgjson.com/api/v5/decks/{}.json"
CACHE_DIR = Path("data/mtgjson/decks")
# Re-download DeckList.json once the cached copy is older than this, so new
# releases show up. Deck files are kept: a released precon doesn't change.
DECK_LIST_MAX_AGE = 24 * 3600

# Play format -> the MTGJSON deck type whose decks seed it, in output order.
DECK_TYPES: dict[str, str] = {
    "standard": "Challenger Deck",
    "pioneer": "Pioneer Challenger Deck",
    "modern": "Modern Event Deck",
    "commander": "Commander Deck",
}
TRIES = 3


class DeckSource:
    """MTGJSON's DeckList.json and deck files: read from `from_dir` when given
    (offline use, tests), else downloaded from mtgjson.com and cached in
    `cache_dir`."""

    def __init__(self, from_dir: Path | str | None = None, cache_dir: Path | str = CACHE_DIR):
        self.from_dir = Path(from_dir) if from_dir else None
        self.cache_dir = Path(cache_dir)

    def deck_list(self) -> list[dict]:
        """Every entry of DeckList.json: code, fileName, name, releaseDate, type."""
        if self.from_dir:
            text = (self.from_dir / "DeckList.json").read_text(encoding="utf-8")
        else:
            cached = self.cache_dir / "DeckList.json"
            fresh = cached.exists() and time.time() - cached.stat().st_mtime < DECK_LIST_MAX_AGE
            text = cached.read_text(encoding="utf-8") if fresh else self._download(DECK_LIST_URL, cached)
        return json.loads(text)["data"]

    def deck_text(self, file_name: str) -> str:
        """The deck file for a DeckList entry's `fileName`, as text."""
        if not file_name or Path(file_name).name != file_name or file_name.startswith("."):
            raise ValueError(f"Not a deck file name: {file_name!r}")
        if self.from_dir:
            return (self.from_dir / f"{file_name}.json").read_text(encoding="utf-8")
        cached = self.cache_dir / f"{file_name}.json"
        if cached.exists():
            return cached.read_text(encoding="utf-8")
        return self._download(DECK_URL.format(file_name), cached)

    def _download(self, url: str, dest: Path) -> str:
        # MTGJSON answers 403 to Python's default user agent.
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        with urllib.request.urlopen(req, timeout=120) as resp:
            body = resp.read()
        dest.parent.mkdir(parents=True, exist_ok=True)
        tmp = dest.with_suffix(".part")
        tmp.write_bytes(body)
        tmp.replace(dest)
        return body.decode("utf-8")


def candidates(deck_list: list[dict], play_format: str, taken: set[str], today: date) -> list[dict]:
    """The DeckList entries that could seed `play_format`: its deck type,
    released by `today` (an unreleased deck's cards aren't in the catalogue
    yet), and not named like a deck in `taken`. In DeckList order."""
    deck_type = DECK_TYPES[play_format]
    return [
        e for e in deck_list
        if e.get("type") == deck_type
        and e.get("name") not in taken
        and (e.get("releaseDate") or "") <= today.isoformat()
    ]


def format_rng(seed: int, play_format: str) -> random.Random:
    """The random source for one format's pick. Each format gets its own, so
    `--format` doesn't change the picks for the formats that do run."""
    return random.Random(f"{seed}:{play_format}")


def try_order(entries: list[dict], rng: random.Random, tries: int) -> list[dict]:
    """Up to `tries` distinct entries, in the order they are tried."""
    return rng.sample(entries, min(tries, len(entries)))


@dataclass
class Pick:
    entry: dict
    legal: bool
    tried: list[str] = field(default_factory=list)


def pick(entries: list[dict], rng: random.Random, is_legal: Callable[[dict], bool], tries: int = TRIES) -> Pick | None:
    """Pick one entry at random, preferring a legal one: try up to `tries`
    random entries and take the first that `is_legal` accepts, else the last
    one tried. None when there is nothing to pick."""
    order = try_order(entries, rng, tries)
    if not order:
        return None
    tried: list[str] = []
    legal = False
    for entry in order:
        tried.append(entry["name"])
        legal = is_legal(entry)
        if legal:
            break
    return Pick(entry=entry, legal=legal, tried=tried)
