"""Build the local card catalogue from MTGJSON AtomicCards and Scryfall's
oracle tags.

One row per oracle card (MTGJSON keys AtomicCards by card name), plus an FTS5
index over name, type line and rules text, plus Scryfall's community oracle
tags (a `tags` table and a `card_tags(oracle_id, tag)` join on the same
oracle id), plus the MTGJSON version and build date in a meta table.

    uv run python -m catalog.ingest                          # download everything, then build
    uv run python -m catalog.ingest --source FILE             # local AtomicCards .json or .json.xz
    uv run python -m catalog.ingest --tags-source FILE        # local oracle tags .jsonl or .jsonl.gz
"""

from __future__ import annotations

import argparse
import gzip
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

# Scryfall, like MTGJSON, answers 403 to a default urllib user agent, and
# api.scryfall.com (unlike its data.scryfall.io CDN) also 400s without an
# Accept header: https://scryfall.com/docs/api
SCRYFALL_BULK_DATA_URL = "https://api.scryfall.com/bulk-data"
DEFAULT_TAGS_DOWNLOAD = Path("data/scryfall/oracle-tags.jsonl.gz")

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
    legalities TEXT NOT NULL        -- JSON object, format -> "Legal" / "Banned" / "Restricted"
);
CREATE UNIQUE INDEX cards_name ON cards(name COLLATE NOCASE);
CREATE VIRTUAL TABLE cards_fts USING fts5(
    name, type_line, text,
    content='cards', content_rowid='rowid',
    tokenize='unicode61 remove_diacritics 2'
);
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE tags (
    slug TEXT PRIMARY KEY,
    description TEXT NOT NULL,
    parent_slugs TEXT NOT NULL  -- JSON list
);
CREATE TABLE card_tags (
    oracle_id TEXT NOT NULL,
    tag TEXT NOT NULL,
    PRIMARY KEY (oracle_id, tag)
);
CREATE INDEX card_tags_oracle_id ON card_tags(oracle_id);
"""


def db_path() -> Path:
    """Where the catalogue lives. KP_CATALOG overrides the default."""
    return Path(os.environ.get("KP_CATALOG", DEFAULT_DB))


def load_atomic(source: Path) -> dict:
    opener = lzma.open if source.suffix == ".xz" else open
    with opener(source, "rt", encoding="utf-8") as fh:
        return json.load(fh)


def load_oracle_tags(source: Path) -> tuple[list[tuple], list[tuple]]:
    """Parse Scryfall's oracle tags JSONL (gzipped or plain) into `tags` and
    `card_tags` rows. Each line is one tag object: {id, slug, type, description,
    parent_ids, taggings: [{oracle_id, weight}, ...]}. `type` is "oracle" for
    this file but is checked anyway in case a mixed file is ever pointed at
    this function. `parent_ids` reference other tags by `id`, not `slug`; this
    resolves them to `parent_slugs` using the id -> slug map built from the
    same file."""
    opener = gzip.open if source.suffix == ".gz" else open
    records: list[dict] = []
    slug_by_id: dict[str, str] = {}
    with opener(source, "rt", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            if rec.get("type") != "oracle":
                continue
            records.append(rec)
            slug_by_id[rec["id"]] = rec["slug"]

    tag_rows: dict[str, tuple] = {}
    card_tag_rows: dict[tuple[str, str], tuple] = {}
    for rec in records:
        slug = rec["slug"]
        parent_slugs = [slug_by_id[pid] for pid in rec.get("parent_ids", []) if pid in slug_by_id]
        tag_rows.setdefault(slug, (slug, rec.get("description") or "", json.dumps(parent_slugs)))
        for tagging in rec.get("taggings", []):
            oracle_id = tagging.get("oracle_id")
            if oracle_id:
                card_tag_rows.setdefault((oracle_id, slug), (oracle_id, slug))

    return list(tag_rows.values()), list(card_tag_rows.values())


def card_row(name: str, faces: list[dict]) -> tuple:
    """Flatten one MTGJSON atomic card (one or more faces) into a cards row."""
    first = faces[0]
    oracle_id = first.get("identifiers", {}).get("scryfallOracleId") or name
    types: list[str] = []
    for face in faces:
        for t in face.get("types", []):
            if t not in types:
                types.append(t)
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
    )


def build(atomic: dict, out: Path, tags: tuple[list[tuple], list[tuple]] | None = None) -> dict:
    """Write a fresh catalogue to `out` and return its meta values. `tags` is
    the (tag_rows, card_tag_rows) pair from `load_oracle_tags`; omit it to
    build a catalogue with no tags. A `card_tags` row whose oracle id matches
    no `cards` row is kept as-is (some MTGJSON cards fall back to a synthetic
    non-UUID oracle id when MTGJSON has no Scryfall id for them; those simply
    never gain tags)."""
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
        con.executemany("INSERT INTO cards VALUES (?,?,?,?,?,?,?,?,?)", rows.values())
        con.execute("INSERT INTO cards_fts(cards_fts) VALUES ('rebuild')")
        tag_rows, card_tag_rows = tags or ([], [])
        con.executemany("INSERT INTO tags VALUES (?,?,?)", tag_rows)
        con.executemany("INSERT INTO card_tags VALUES (?,?)", card_tag_rows)
        meta = {
            "mtgjson_version": atomic["meta"]["version"],
            "mtgjson_date": atomic["meta"]["date"],
            "ingested_at": datetime.now(timezone.utc).isoformat(),
            "card_count": str(len(rows)),
            "tag_count": str(len(tag_rows)),
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


def oracle_tags_uri() -> str:
    """The current download URL for Scryfall's oracle_tags bulk file."""
    req = urllib.request.Request(
        SCRYFALL_BULK_DATA_URL,
        headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        index = json.load(resp)
    for entry in index["data"]:
        if entry["type"] == "oracle_tags":
            return entry["jsonl_download_uri"]
    raise ValueError("Scryfall bulk-data has no oracle_tags entry")


def download_oracle_tags(dest: Path) -> Path:
    uri = oracle_tags_uri()
    dest.parent.mkdir(parents=True, exist_ok=True)
    print(f"Downloading {uri} ...", file=sys.stderr)
    req = urllib.request.Request(uri, headers={"User-Agent": USER_AGENT})
    tmp = dest.with_suffix(".part")
    with urllib.request.urlopen(req, timeout=120) as resp, open(tmp, "wb") as out:
        shutil.copyfileobj(resp, out)
    tmp.replace(dest)
    return dest


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--source", type=Path, help="local AtomicCards .json or .json.xz")
    parser.add_argument("--tags-source", type=Path, help="local oracle tags .jsonl or .jsonl.gz")
    parser.add_argument("--out", type=Path, default=None, help="catalogue path (default data/catalog.sqlite)")
    args = parser.parse_args(argv)

    source = args.source or download(DEFAULT_DOWNLOAD)
    tags_source = args.tags_source or download_oracle_tags(DEFAULT_TAGS_DOWNLOAD)
    out = args.out or db_path()
    started = time.perf_counter()
    meta = build(load_atomic(source), out, tags=load_oracle_tags(tags_source))
    print(
        f"Built {out}: {meta['card_count']} cards from MTGJSON {meta['mtgjson_version']} "
        f"({meta['mtgjson_date']}) and {meta['tag_count']} Scryfall oracle tags "
        f"in {time.perf_counter() - started:.1f}s"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
