"""Choosing and fetching MTGJSON precons for seed.jac (catalog/precons.py)."""

import io
import json
import random
from datetime import date
from pathlib import Path

import pytest

from catalog import precons
from catalog.ingest import USER_AGENT

SEED_DIR = Path(__file__).parent / "fixtures" / "mtgjson_seed"
TODAY = date(2026, 11, 9)


def _deck_list() -> list[dict]:
    return precons.DeckSource(from_dir=SEED_DIR).deck_list()


def _names(entries: list[dict]) -> list[str]:
    return [e["name"] for e in entries]


def test_each_play_format_takes_one_mtgjson_deck_type():
    assert precons.DECK_TYPES == {
        "standard": "Challenger Deck",
        "pioneer": "Pioneer Challenger Deck",
        "modern": "Modern Event Deck",
        "commander": "Commander Deck",
    }


def test_candidates_are_the_released_decks_of_the_formats_type_not_already_taken():
    deck_list = _deck_list()
    assert _names(precons.candidates(deck_list, "standard", set(), TODAY)) == [
        "Gruul Stompy", "Mono Red Rally", "Bolt Burn",
    ]
    assert _names(precons.candidates(deck_list, "standard", {"Mono Red Rally"}, TODAY)) == [
        "Gruul Stompy", "Bolt Burn",
    ]
    # Future Commander is released in 2099, so its cards can't be in the catalogue yet.
    assert _names(precons.candidates(deck_list, "commander", set(), TODAY)) == [
        "Temur Roar", "Partners in the Wild",
    ]


def test_pick_tries_in_seeded_order_and_stops_at_the_first_legal_one():
    entries = [{"name": n} for n in "abcde"]
    order = [e["name"] for e in precons.try_order(entries, random.Random(0), 3)]
    legal_one = order[1]
    checked = []

    def is_legal(entry):
        checked.append(entry["name"])
        return entry["name"] == legal_one

    picked = precons.pick(entries, random.Random(0), is_legal, tries=3)
    assert checked == order[:2]
    assert picked.tried == order[:2]
    assert picked.entry["name"] == legal_one
    assert picked.legal is True


def test_pick_skips_illegal_tries_until_a_legal_one():
    entries = [{"name": n, "legal": n == "legal"} for n in ("illegal 1", "illegal 2", "legal")]
    for seed in range(20):
        picked = precons.pick(entries, random.Random(seed), lambda e: e["legal"], tries=3)
        assert picked.entry["name"] == "legal"
        assert picked.legal is True
        assert picked.tried[-1] == "legal"


def test_pick_takes_the_last_try_when_none_is_legal():
    entries = [{"name": n} for n in "abcde"]
    picked = precons.pick(entries, random.Random(3), lambda e: False, tries=3)
    assert len(picked.tried) == 3
    assert picked.entry["name"] == picked.tried[-1]
    assert picked.legal is False


def test_pick_with_one_try_takes_the_first_pick_without_checking():
    entries = [{"name": n} for n in "abc"]

    def never(_entry):
        raise AssertionError("not checked")

    picked = precons.pick(entries, random.Random(1), never, tries=1)
    assert picked.tried == [picked.entry["name"]]
    assert picked.legal is None


def test_pick_of_nothing_is_none():
    assert precons.pick([], random.Random(1), lambda e: True, tries=3) is None


def test_the_same_seed_gives_the_same_order_for_a_format_whatever_else_runs():
    entries = [{"name": str(n)} for n in range(30)]
    first = precons.try_order(entries, precons.format_rng(7, "modern"), 3)
    again = precons.try_order(entries, precons.format_rng(7, "modern"), 3)
    other = precons.try_order(entries, precons.format_rng(8, "modern"), 3)
    assert first == again
    assert first != other


def test_from_dir_reads_the_deck_list_and_deck_files():
    source = precons.DeckSource(from_dir=SEED_DIR)
    assert "Gruul Stompy" in _names(source.deck_list())
    doc = json.loads(source.deck_text("GruulStompy_Q07"))
    assert doc["data"]["name"] == "Gruul Stompy"


class _FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def test_downloads_are_cached_and_sent_with_the_ingest_user_agent(tmp_path, monkeypatch):
    requests = []
    bodies = {
        precons.DECK_LIST_URL: json.dumps({"data": [{"name": "X", "fileName": "X_1", "type": "Commander Deck"}]}),
        precons.DECK_URL.format("X_1"): json.dumps({"data": {"name": "X"}}),
    }

    def fake_urlopen(req, timeout):
        requests.append((req.full_url, req.get_header("User-agent")))
        return _FakeResponse(bodies[req.full_url].encode())

    monkeypatch.setattr(precons.urllib.request, "urlopen", fake_urlopen)
    source = precons.DeckSource(cache_dir=tmp_path)
    assert _names(source.deck_list()) == ["X"]
    assert json.loads(source.deck_text("X_1"))["data"]["name"] == "X"
    assert (tmp_path / "DeckList.json").exists()
    assert (tmp_path / "X_1.json").exists()

    # A second source reuses the cache: no more requests.
    again = precons.DeckSource(cache_dir=tmp_path)
    assert _names(again.deck_list()) == ["X"]
    assert json.loads(again.deck_text("X_1"))["data"]["name"] == "X"
    assert requests == [
        (precons.DECK_LIST_URL, USER_AGENT),
        (precons.DECK_URL.format("X_1"), USER_AGENT),
    ]


def test_a_stale_cached_deck_list_is_downloaded_again(tmp_path, monkeypatch):
    import os
    import time

    cached = tmp_path / "DeckList.json"
    cached.write_text(json.dumps({"data": [{"name": "Old"}]}))
    old = time.time() - 2 * 24 * 3600
    os.utime(cached, (old, old))
    monkeypatch.setattr(
        precons.urllib.request, "urlopen",
        lambda req, timeout: _FakeResponse(json.dumps({"data": [{"name": "New"}]}).encode()),
    )
    assert _names(precons.DeckSource(cache_dir=tmp_path).deck_list()) == ["New"]


def test_a_deck_file_names_a_file_not_a_path():
    with pytest.raises(ValueError):
        precons.DeckSource(from_dir=SEED_DIR).deck_text("../DeckList")
