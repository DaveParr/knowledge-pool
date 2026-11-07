"""Build the local card catalogue from MTGJSON AtomicCards.

One row per oracle card (MTGJSON keys AtomicCards by card name), plus an FTS5
index over name, type line and rules text, plus the MTGJSON version and build
date in a meta table.

    uv run python -m catalog.ingest                 # download AtomicCards, then build
    uv run python -m catalog.ingest --source FILE   # build from a local .json or .json.xz
"""

from __future__ import annotations

import argparse
import json
import lzma
import os
import shutil
import sqlite3
import sys
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ATOMIC_URL = "https://mtgjson.com/api/v5/AtomicCards.json.xz"
# MTGJSON answers 403 to Python's default "Python-urllib" user agent.
USER_AGENT = "knowledge-pool-ingest/0.1 (+https://github.com/DaveParr/knowledge-pool)"
DEFAULT_DB = Path("data/catalog.sqlite")
DEFAULT_DOWNLOAD = Path("data/mtgjson/AtomicCards.json.xz")

SCHEMA = """
CREATE TABLE cards (
    oracle_id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    mana_cost TEXT NOT NULL,
    mana_value REAL NOT NULL,
    colour_identity TEXT NOT NULL,  -- JSON list, e.g. ["R", "W"]
    types TEXT NOT NULL,            -- JSON list, e.g. ["Creature"]
    type_line TEXT NOT NULL,
    text TEXT NOT NULL,
    legalities TEXT NOT NULL,       -- JSON object, format -> "Legal" / "Banned" / "Restricted"
    produced_mana TEXT NOT NULL     -- JSON list, e.g. ["W", "U"]
);
CREATE UNIQUE INDEX cards_name ON cards(name COLLATE NOCASE);
CREATE VIRTUAL TABLE cards_fts USING fts5(
    name, type_line, text,
    content='cards', content_rowid='rowid',
    tokenize='unicode61 remove_diacritics 2'
);
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
"""


def db_path() -> Path:
    """Where the catalogue lives. KP_CATALOG overrides the default."""
    return Path(os.environ.get("KP_CATALOG", DEFAULT_DB))


def load_atomic(source: Path) -> dict:
    opener = lzma.open if source.suffix == ".xz" else open
    with opener(source, "rt", encoding="utf-8") as fh:
        return json.load(fh)


def card_row(name: str, faces: list[dict]) -> tuple:
    """Flatten one MTGJSON atomic card (one or more faces) into a cards row."""
    first = faces[0]
    oracle_id = first.get("identifiers", {}).get("scryfallOracleId") or name
    types: list[str] = []
    produced_mana: list[str] = []
    for face in faces:
        for t in face.get("types", []):
            if t not in types:
                types.append(t)
        for m in face.get("producedMana", []):
            if m not in produced_mana:
                produced_mana.append(m)
    return (
        oracle_id,
        name,
        " // ".join(f.get("manaCost", "") for f in faces if f.get("manaCost")),
        float(first.get("manaValue", 0.0)),
        json.dumps(first.get("colorIdentity", [])),
        json.dumps(types),
        " // ".join(f.get("type", "") for f in faces),
        "\n//\n".join(f.get("text", "") for f in faces if f.get("text")),
        json.dumps(first.get("legalities", {})),
        json.dumps(produced_mana),
    )


def build(atomic: dict, out: Path) -> dict:
    """Write a fresh catalogue to `out` and return its meta values."""
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_suffix(".building")
    tmp.unlink(missing_ok=True)
    con = sqlite3.connect(tmp)
    try:
        con.executescript(SCHEMA)
        rows: dict[str, tuple] = {}
        for name, faces in atomic["data"].items():
            row = card_row(name, faces)
            rows.setdefault(row[0], row)  # same oracle id twice: keep the first
        con.executemany("INSERT INTO cards VALUES (?,?,?,?,?,?,?,?,?,?)", rows.values())
        con.execute("INSERT INTO cards_fts(cards_fts) VALUES ('rebuild')")
        meta = {
            "mtgjson_version": atomic["meta"]["version"],
            "mtgjson_date": atomic["meta"]["date"],
            "ingested_at": datetime.now(timezone.utc).isoformat(),
            "card_count": str(len(rows)),
        }
        con.executemany("INSERT INTO meta VALUES (?, ?)", meta.items())
        con.commit()
    finally:
        con.close()
    tmp.replace(out)
    return meta


def download(dest: Path) -> Path:
    dest.parent.mkdir(parents=True, exist_ok=True)
    print(f"Downloading {ATOMIC_URL} ...", file=sys.stderr)
    req = urllib.request.Request(ATOMIC_URL, headers={"User-Agent": USER_AGENT})
    tmp = dest.with_suffix(".part")
    with urllib.request.urlopen(req, timeout=120) as resp, open(tmp, "wb") as out:
        shutil.copyfileobj(resp, out)
    tmp.replace(dest)
    return dest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--source", type=Path, help="local AtomicCards .json or .json.xz")
    parser.add_argument("--out", type=Path, default=None, help="catalogue path (default data/catalog.sqlite)")
    args = parser.parse_args(argv)

    source = args.source or download(DEFAULT_DOWNLOAD)
    out = args.out or db_path()
    started = time.perf_counter()
    meta = build(load_atomic(source), out)
    print(
        f"Built {out}: {meta['card_count']} cards from MTGJSON {meta['mtgjson_version']} "
        f"({meta['mtgjson_date']}) in {time.perf_counter() - started:.1f}s"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
