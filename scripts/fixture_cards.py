"""Grow the hand-trimmed MTGJSON test fixtures from real MTGJSON data.

    .jac/venv/bin/python scripts/fixture_cards.py precon SRC DEST
    .jac/venv/bin/python scripts/fixture_cards.py cards --atomic AtomicCards.json.xz \
        [--deck tests/fixtures/mtgjson_decks/X.json ...] [NAME ...]

`precon` trims a downloaded MTGJSON deck file to names, counts and oracle ids.
`cards` copies named cards, and every card in each trimmed deck file, from a
full AtomicCards file into tests/fixtures/atomic_small.json. A card already in
the fixture keeps everything it has; only `leadershipSkills` and
`isGameChanger` are set from the source, so existing legality results don't move.
The files are untrusted downloads: this reads them with `json` only.
"""

from __future__ import annotations

import argparse
import json
import lzma
import sys
from pathlib import Path

FIXTURE = Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "atomic_small.json"
FACE_KEYS = (
    "colorIdentity", "identifiers", "layout", "legalities", "manaCost", "manaValue",
    "name", "subtypes", "supertypes", "text", "type", "types",
)
EXTRA_KEYS = ("leadershipSkills", "isGameChanger")


def load_json(path: Path) -> dict:
    opener = lzma.open if path.suffix == ".xz" else open
    with opener(path, "rt", encoding="utf-8") as fh:
        return json.load(fh)


def write_json(path: Path, data: dict) -> None:
    path.write_text(json.dumps(data, indent=1) + "\n", encoding="utf-8")


def trim_card(card: dict) -> dict:
    return {
        "name": card["name"],
        "count": card.get("count", 1),
        "identifiers": {"scryfallOracleId": card["identifiers"]["scryfallOracleId"]},
    }


def as_cards(value) -> list[dict]:
    """MTGJSON gives a zone as a list of cards; a lone companion may be one card."""
    if not value:
        return []
    return value if isinstance(value, list) else [value]


def precon(src: Path, dest: Path) -> None:
    raw = load_json(src)
    data = raw["data"]
    out = {key: data[key] for key in ("name", "code", "type", "releaseDate")}
    out["commander"] = [trim_card(c) for c in as_cards(data.get("commander"))]
    if data.get("companion"):
        out["companion"] = [trim_card(c) for c in as_cards(data["companion"])]
    out["mainBoard"] = [trim_card(c) for c in as_cards(data.get("mainBoard"))]
    out["sideBoard"] = [trim_card(c) for c in as_cards(data.get("sideBoard"))]
    dest.parent.mkdir(parents=True, exist_ok=True)
    write_json(dest, {"meta": raw["meta"], "data": out})


def deck_names(path: Path) -> list[str]:
    data = load_json(path)["data"]
    names: list[str] = []
    for zone in ("commander", "companion", "mainBoard", "sideBoard"):
        names += [c["name"] for c in as_cards(data.get(zone))]
    return names


def source_name(atomic: dict, name: str) -> str | None:
    """The AtomicCards key for a name: exact, else a double-faced card by either face."""
    if name in atomic:
        return name
    for key in atomic:
        if name in key.split(" // "):
            return key
    return None


def add_cards(atomic_path: Path, names: list[str], decks: list[Path], fixture: Path = FIXTURE) -> list[str]:
    """Update the fixture; return the names the source doesn't have."""
    source = load_json(atomic_path)["data"]
    target = load_json(fixture)
    wanted = list(dict.fromkeys(list(target["data"]) + names + [n for d in decks for n in deck_names(d)]))
    missing: list[str] = []
    for name in wanted:
        key = source_name(source, name)
        if key is None:
            missing.append(name)
            continue
        faces = target["data"].get(key)
        if faces is None:
            faces = [{k: f[k] for k in sorted(FACE_KEYS) if k in f} for f in source[key]]
            target["data"][key] = faces
        for face, src_face in zip(faces, source[key]):
            for extra in EXTRA_KEYS:
                if extra in src_face:
                    face[extra] = src_face[extra]
            for k in sorted(face):  # the fixture keeps each face's keys sorted
                face[k] = face.pop(k)
    write_json(fixture, target)
    return missing


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("precon", help="trim a downloaded MTGJSON deck file")
    p.add_argument("src", type=Path)
    p.add_argument("dest", type=Path)
    c = sub.add_parser("cards", help="add cards to tests/fixtures/atomic_small.json")
    c.add_argument("--atomic", type=Path, required=True, help="AtomicCards .json or .json.xz")
    c.add_argument("--deck", type=Path, action="append", default=[], help="trimmed deck file; repeatable")
    c.add_argument("names", nargs="*")
    args = parser.parse_args(argv)

    if args.command == "precon":
        precon(args.src, args.dest)
        return 0
    missing = add_cards(args.atomic, args.names, args.deck)
    if missing:
        print("Not found in source: " + "; ".join(missing), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
