"""`jac run seed.jac` against the fixture DeckList (no network) and a throwaway graph."""

import json
import os
import socket
import subprocess
import sys
from pathlib import Path

from jaclang.runtimelib.testing import JacTestClient

from catalog import precons

ROOT = Path(__file__).resolve().parent.parent
SEED_DIR = Path(__file__).parent / "fixtures" / "mtgjson_seed"
# Fixture decks that break their format's rules today.
ILLEGAL = {"Gruul Stompy", "Bolt Burn", "Pioneer Iteration", "Modern Mox"}


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def _seed(catalog: Path, graph: Path, *args: str, port: int | None = None) -> subprocess.CompletedProcess:
    env = {
        **os.environ, "KP_CATALOG": str(catalog), "JAC_DATA_PATH": str(graph),
        "KP_PORT": str(port or _free_port()),
    }
    return subprocess.run(
        [str(Path(sys.executable).parent / "jac"), "run", str(ROOT / "seed.jac"), "--from-dir", str(SEED_DIR), *args],
        cwd=ROOT, env=env, capture_output=True, text=True, timeout=300,
    )


def _ok(run: subprocess.CompletedProcess) -> str:
    assert run.returncode == 0, run.stdout + run.stderr
    return run.stdout


def _decks(graph: Path) -> dict[str, dict]:
    """Every deck in the graph's shared root, by name: its play format and card counts per zone."""
    client = JacTestClient.from_file("main.jac", base_path=str(graph))
    try:
        listed = client.post("/walker/ListDecks").json()["data"]["reports"][0]
        out = {}
        for d in listed:
            view = client.post("/walker/GetDeck", json={"deck_id": d["_jac_id"]}).json()["data"]["reports"][0]
            zones: dict[str, int] = {}
            for c in view["cards"]:
                zones[c["zone"]] = zones.get(c["zone"], 0) + c["count"]
            out[view["name"]] = {"format": view["format"], "zones": zones, "legal": view["legal"]}
        return out
    finally:
        client.close()


def _fixture_counts(name: str) -> dict[str, int]:
    entry = next(e for e in json.loads((SEED_DIR / "DeckList.json").read_text())["data"] if e["name"] == name)
    doc = json.loads((SEED_DIR / f"{entry['fileName']}.json").read_text())["data"]
    keys = {"commander": "commander", "mainBoard": "main", "sideBoard": "sideboard"}
    counts = {zone: sum(e["count"] for e in doc.get(key, [])) for key, zone in keys.items()}
    return {zone: n for zone, n in counts.items() if n}


def _format_lines(out: str) -> dict[str, str]:
    lines = {}
    for line in out.splitlines():
        head = line.split(":", 1)[0]
        if head in precons.DECK_TYPES:
            lines[head] = line
    return lines


def _first_try(seed: int, play_format: str) -> str:
    deck_list = json.loads((SEED_DIR / "DeckList.json").read_text())["data"]
    from datetime import date
    entries = precons.candidates(deck_list, play_format, set(), date.today())
    return precons.try_order(entries, precons.format_rng(seed, play_format), precons.TRIES)[0]["name"]


# A seed whose first standard try is an illegal deck, so the legal-first retry runs.
SEED = next(s for s in range(100) if _first_try(s, "standard") in ILLEGAL)


def test_seed_adds_one_precon_per_format_then_different_ones(fixture_catalog, tmp_path):
    graph = tmp_path / "graph"
    out = _ok(_seed(fixture_catalog, graph, "--seed", str(SEED)))
    assert f"Seed: {SEED}" in out
    lines = _format_lines(out)
    assert list(lines) == ["standard", "pioneer", "modern", "commander"]
    assert len(out.splitlines()) == 5  # the seed, then one line per format and nothing else

    decks = _decks(graph)
    assert len(decks) == 4
    for name, deck in decks.items():
        assert deck["zones"] == _fixture_counts(name), name
    by_format = {}
    for name, deck in decks.items():
        by_format.setdefault(deck["format"], []).append(name)
    # The commander pick falls back to standard until there is a commander format.
    commander = next(n for n in decks if n in ("Temur Roar", "Partners in the Wild"))
    assert decks[commander]["legal"] is False
    assert "illegal" in lines["commander"]
    assert commander in lines["commander"] and "Commander Deck" in lines["commander"]

    # Legal-first: the first standard try was illegal, but a legal deck was taken,
    # and the rejected try left no deck behind.
    assert "Mono Red Rally" in decks and decks["Mono Red Rally"]["legal"] is True
    assert not (set(decks) & ILLEGAL)
    assert "Mono Red Rally" in lines["standard"] and " legal" in lines["standard"]
    assert "Challenger Deck" in lines["standard"] and "2025-03-01" in lines["standard"]
    assert "Pioneer Monks" in lines["pioneer"] and decks["Pioneer Monks"]["format"] == "pioneer"
    assert "Modern Burn" in lines["modern"] and decks["Modern Burn"]["format"] == "modern"

    # The same seed again: decks already in the graph are skipped, so new ones are added.
    _ok(_seed(fixture_catalog, graph, "--seed", str(SEED)))
    again = _decks(graph)
    assert len(again) == 8
    assert set(decks) < set(again)
    for name in set(again) - set(decks):
        assert again[name]["zones"] == _fixture_counts(name), name
    # Every released commander precon is now in the graph. Future Commander is
    # not released yet, so a third run has no commander left to add.
    third = _ok(_seed(fixture_catalog, graph, "--seed", str(SEED), "--format", "commander"))
    assert "no precon left" in _format_lines(third)["commander"]
    assert "Future Commander" not in _decks(graph)


def test_format_flag_limits_the_run(fixture_catalog, tmp_path):
    graph = tmp_path / "graph"
    out = _ok(_seed(fixture_catalog, graph, "--seed", "5", "--format", "modern", "--format", "pioneer"))
    assert set(_format_lines(out)) == {"pioneer", "modern"}
    assert sorted(d["format"] for d in _decks(graph).values()) == ["modern", "pioneer"]


def test_refuses_to_run_while_the_app_is_up(fixture_catalog, tmp_path):
    graph = tmp_path / "graph"
    with socket.socket() as busy:
        busy.bind(("127.0.0.1", 0))
        busy.listen()
        port = busy.getsockname()[1]
        run = _seed(fixture_catalog, graph, "--seed", "1", port=port)
    assert run.returncode == 1
    assert f"Port {port} is in use" in run.stderr
    assert not (graph / ".jac" / "data").exists()
