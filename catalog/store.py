"""Read side of the card catalogue: search and lookup over data/catalog.sqlite."""

from __future__ import annotations

import json
import re
import sqlite3
from functools import lru_cache

from catalog.ingest import db_path

_COLUMNS = "c.oracle_id, c.name, c.mana_cost, c.mana_value, c.colour_identity, c.types, c.type_line, c.text, c.legalities"
_WORD = re.compile(r"[\w']+", re.UNICODE)


@lru_cache(maxsize=4)
def _connect(path: str) -> sqlite3.Connection:
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True, check_same_thread=False)
    con.row_factory = sqlite3.Row
    return con


def connection() -> sqlite3.Connection:
    path = db_path()
    if not path.exists():
        raise FileNotFoundError(f"No card catalogue at {path}. Run: uv run python -m catalog.ingest")
    return _connect(str(path.resolve()))


def reset() -> None:
    """Forget open connections (tests point KP_CATALOG at a new file)."""
    _connect.cache_clear()


def _card(row: sqlite3.Row) -> dict:
    return {
        "oracle_id": row["oracle_id"],
        "name": row["name"],
        "mana_cost": row["mana_cost"],
        "mana_value": row["mana_value"],
        "colour_identity": json.loads(row["colour_identity"]),
        "types": json.loads(row["types"]),
        "type_line": row["type_line"],
        "text": row["text"],
        "legal": json.loads(row["legalities"]),
    }


def fts_query(text: str) -> str:
    """Turn free text into a safe FTS5 query: every word must match, as a prefix."""
    words = _WORD.findall(text)
    return " ".join(f'"{w}"*' for w in words)


def search(text: str, limit: int = 25) -> list[dict]:
    """Cards whose name, type line or rules text match every word. Name hits rank first."""
    query = fts_query(text)
    if not query:
        return []
    rows = connection().execute(
        f"SELECT {_COLUMNS} FROM cards_fts f JOIN cards c ON c.rowid = f.rowid "
        "WHERE cards_fts MATCH ? ORDER BY bm25(cards_fts, 10.0, 2.0, 1.0) LIMIT ?",
        (query, limit),
    )
    return [_card(r) for r in rows]


def get_card(oracle_id: str) -> dict | None:
    row = connection().execute(f"SELECT {_COLUMNS} FROM cards c WHERE oracle_id = ?", (oracle_id,)).fetchone()
    return _card(row) if row else None


def meta() -> dict[str, str]:
    return {k: v for k, v in connection().execute("SELECT key, value FROM meta")}
