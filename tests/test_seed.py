"""`jac run seed.jac` against the fixture DeckList (no network) and a throwaway database."""

import json
import os
import subprocess
import sys
from pathlib import Path

from catalog import precons
from tests.local_decks import local_user_decks

ROOT = Path(__file__).resolve().parent.parent
SEED_DIR = Path(__file__).parent / "fixtures" / "mtgjson_seed"
# Fixture decks that break their format's rules today.
ILLEGAL = {"Gruul Stompy", "Bolt Burn", "Pioneer Iteration", "Modern Mox"}


def _seed(catalog: Path, db_url: str, *args: str) -> subprocess.CompletedProcess:
    env = {**os.environ, "KP_CATALOG": str(catalog), "JAC_DB_URL": db_url}
    return subprocess.run(
        [sys.executable, "run", "--no-serve", str(ROOT / "seed.jac"), "--from-dir", str(SEED_DIR), *args],
        cwd=ROOT, env=env, capture_output=True, text=True, timeout=300,
    )


def _ok(run: subprocess.CompletedProcess) -> str:
    assert run.returncode == 0, run.stdout + run.stderr
    return run.stdout


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


def test_seed_adds_one_precon_per_format_then_different_ones(fixture_catalog, jac_db_url, tmp_path):
    out = _ok(_seed(fixture_catalog, jac_db_url, "--seed", str(SEED)))
    assert f"Seed: {SEED}" in out
    lines = _format_lines(out)
    assert list(lines) == ["standard", "pioneer", "modern", "commander"]
    assert len(out.splitlines()) == 5  # the seed, then one line per format and nothing else

    decks = local_user_decks(jac_db_url, tmp_path)
    assert len(decks) == 4
    for name, deck in decks.items():
        assert deck["zones"] == _fixture_counts(name), name
    by_format = {}
    for name, deck in decks.items():
        by_format.setdefault(deck["format"], []).append(name)
    # Commander picks legal-first too: Temur Roar is a legal commander deck,
    # Partners in the Wild (too few cards) is not.
    assert decks["Temur Roar"]["format"] == "commander" and decks["Temur Roar"]["legal"] is True
    assert "Temur Roar" in lines["commander"] and "Commander Deck" in lines["commander"]
    assert " legal" in lines["commander"]

    # Legal-first: the first standard try was illegal, but a legal deck was taken,
    # and the rejected try left no deck behind.
    assert "Mono Red Rally" in decks and decks["Mono Red Rally"]["legal"] is True
    assert not (set(decks) & ILLEGAL)
    assert "Mono Red Rally" in lines["standard"] and " legal" in lines["standard"]
    assert "Challenger Deck" in lines["standard"] and "2025-03-01" in lines["standard"]
    assert "Pioneer Monks" in lines["pioneer"] and decks["Pioneer Monks"]["format"] == "pioneer"
    assert "Modern Burn" in lines["modern"] and decks["Modern Burn"]["format"] == "modern"

    # The same seed again: decks already in the graph are skipped, so new ones are added.
    _ok(_seed(fixture_catalog, jac_db_url, "--seed", str(SEED)))
    again = local_user_decks(jac_db_url, tmp_path)
    assert len(again) == 8
    assert set(decks) < set(again)
    for name in set(again) - set(decks):
        assert again[name]["zones"] == _fixture_counts(name), name
    # Every released commander precon is now in the graph. Future Commander is
    # not released yet, so a third run has no commander left to add.
    third = _ok(_seed(fixture_catalog, jac_db_url, "--seed", str(SEED), "--format", "commander"))
    assert "no precon left" in _format_lines(third)["commander"]
    assert "Future Commander" not in local_user_decks(jac_db_url, tmp_path)


def test_format_flag_limits_the_run(fixture_catalog, jac_db_url, tmp_path):
    out = _ok(_seed(fixture_catalog, jac_db_url, "--seed", "5", "--format", "modern", "--format", "pioneer"))
    assert set(_format_lines(out)) == {"pioneer", "modern"}
    assert sorted(d["format"] for d in local_user_decks(jac_db_url, tmp_path).values()) == ["modern", "pioneer"]


def test_seed_runs_while_the_dev_server_is_up_and_adds_the_local_users_deck(fixture_catalog, jac_db_url, tmp_path):
    script = ROOT / "scripts" / "dev.sh"
    env = {**os.environ, "KP_CATALOG": str(fixture_catalog), "KP_DEV_DIR": str(tmp_path / "dev")}
    try:
        up = subprocess.run([str(script), "up"], env=env, cwd=ROOT, capture_output=True, text=True, timeout=300)
        assert up.returncode == 0, up.stdout + up.stderr
        _ok(_seed(fixture_catalog, jac_db_url, "--seed", "5", "--format", "modern"))
        assert len(local_user_decks(jac_db_url, tmp_path)) == 1
    finally:
        subprocess.run([str(script), "down"], env=env, cwd=ROOT, timeout=60)
