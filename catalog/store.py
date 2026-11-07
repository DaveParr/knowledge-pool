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


def _tags_for(con: sqlite3.Connection, oracle_id: str) -> list[str]:
    return [r[0] for r in con.execute("SELECT tag FROM card_tags WHERE oracle_id = ? ORDER BY tag", (oracle_id,))]


def _card(row: sqlite3.Row, con: sqlite3.Connection) -> dict:
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
        "oracle_tags": _tags_for(con, row["oracle_id"]),
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
    con = connection()
    rows = con.execute(
        f"SELECT {_COLUMNS} FROM cards_fts f JOIN cards c ON c.rowid = f.rowid "
        "WHERE cards_fts MATCH ? ORDER BY bm25(cards_fts, 10.0, 2.0, 1.0) LIMIT ?",
        (query, limit),
    )
    return [_card(r, con) for r in rows]


def get_card(oracle_id: str) -> dict | None:
    con = connection()
    row = con.execute(f"SELECT {_COLUMNS} FROM cards c WHERE oracle_id = ?", (oracle_id,)).fetchone()
    return _card(row, con) if row else None


def meta() -> dict[str, str]:
    return {k: v for k, v in connection().execute("SELECT key, value FROM meta")}


@lru_cache(maxsize=4)
def _all_names(path: str) -> tuple[str, ...]:
    return tuple(r[0] for r in _connect(path).execute("SELECT name FROM cards"))


def find_by_name(name: str) -> dict | None:
    """Exact card name, ignoring case. A double-faced card also matches by either face."""
    con = connection()
    cleaned = name.strip()
    row = con.execute(f"SELECT {_COLUMNS} FROM cards c WHERE c.name = ? COLLATE NOCASE", (cleaned,)).fetchone()
    if row is None:
        row = con.execute(
            f"SELECT {_COLUMNS} FROM cards c WHERE c.name LIKE ? OR c.name LIKE ? LIMIT 1",
            (f"{cleaned} // %", f"% // {cleaned}"),
        ).fetchone()
    return _card(row, con) if row else None


def close_names(name: str, limit: int = 5) -> list[str]:
    """Card names that look like `name`: spelling matches first, then name-word matches."""
    import difflib

    names = _all_names(str(db_path().resolve()))
    found = difflib.get_close_matches(name, names, n=limit, cutoff=0.75)
    lowered = {n.lower(): n for n in found}
    if len(found) < limit:
        words = fts_query(name)
        if words:
            rows = connection().execute(
                "SELECT c.name FROM cards_fts f JOIN cards c ON c.rowid = f.rowid "
                "WHERE cards_fts MATCH ? ORDER BY bm25(cards_fts, 10.0, 0.0, 0.0) LIMIT ?",
                (f"name : ({words})", limit),
            )
            for (n,) in rows:
                if n.lower() not in lowered and len(found) < limit:
                    found.append(n)
                    lowered[n.lower()] = n
    return found


def resolve_names(names: list[str]) -> dict:
    """Sort names into exact matches, fuzzy candidates and unknowns. Never guesses."""
    exact, fuzzy, unknown = [], [], []
    for raw in names:
        card = find_by_name(raw)
        if card is not None:
            exact.append({"input": raw, "oracle_id": card["oracle_id"], "name": card["name"]})
            continue
        candidates = [find_by_name(n) for n in close_names(raw)]
        candidates = [{"oracle_id": c["oracle_id"], "name": c["name"]} for c in candidates if c]
        if candidates:
            fuzzy.append({"input": raw, "candidates": candidates})
        else:
            unknown.append(raw)
    return {"exact": exact, "fuzzy": fuzzy, "unknown": unknown}
