"""Ingest of the MTGJSON fixture, and search over the result."""

import time

from catalog import store
from catalog.ingest import main


def test_meta_records_mtgjson_version_and_date():
    meta = store.meta()
    assert meta["mtgjson_version"] == "5.3.0+fixture"
    assert meta["mtgjson_date"] == "2026-01-01"
    assert meta["ingested_at"]
    assert meta["card_count"] == "33"


def test_one_row_per_oracle_card_with_its_fields():
    bolt = store.search("lightning bolt")[0]
    assert bolt["name"] == "Lightning Bolt"
    assert bolt["mana_value"] == 1.0
    assert bolt["colour_identity"] == ["R"]
    assert bolt["types"] == ["Instant"]
    assert bolt["legal"]["modern"] == "Legal"
    assert bolt["produced_mana"] == []
    assert store.get_card(bolt["oracle_id"])["name"] == "Lightning Bolt"


def test_produced_mana_is_stored_from_mtgjson():
    mountain = store.find_by_name("Mountain")
    assert mountain["produced_mana"] == ["R"]
    chrome_mox = store.find_by_name("Chrome Mox")
    assert chrome_mox["produced_mana"] == ["W", "U", "B", "R", "G"]
    fetchland = store.find_by_name("Bloodstained Mire")
    assert fetchland["produced_mana"] == []


def test_split_card_keeps_both_faces():
    fire_ice = store.search("Fire Ice")[0]
    assert fire_ice["name"] == "Fire // Ice"
    assert fire_ice["type_line"] == "Instant // Instant"
    assert "Tap target permanent" in fire_ice["text"]


def test_search_by_rules_text():
    names = {c["name"] for c in store.search("deals 3 damage")}
    assert "Lightning Bolt" in names


def test_search_matches_prefixes_and_ignores_punctuation():
    assert store.search("llano")[0]["name"] == "Llanowar Elves"
    assert store.search('bolt" (')[0]["name"] == "Lightning Bolt"
    assert store.search("  ") == []
    assert store.search("xyzzy") == []


def test_search_is_fast():
    store.search("creature")
    started = time.perf_counter()
    store.search("creature")
    assert time.perf_counter() - started < 0.1


def test_ingest_command_builds_from_a_local_file(tmp_path, capsys):
    from tests.conftest import FIXTURE

    out = tmp_path / "cli.sqlite"
    assert main(["--source", str(FIXTURE), "--out", str(out)]) == 0
    assert "33 cards from MTGJSON 5.3.0+fixture (2026-01-01)" in capsys.readouterr().out
    assert out.exists()


def test_download_sends_a_user_agent(tmp_path, monkeypatch):
    """MTGJSON returns 403 to Python's default user agent."""
    import io
    import urllib.request

    from catalog import ingest

    seen = {}

    def fake_urlopen(req, timeout=None):
        seen["ua"] = req.get_header("User-agent")
        return io.BytesIO(b"data")

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    dest = ingest.download(tmp_path / "AtomicCards.json.xz")
    assert dest.read_bytes() == b"data"
    assert seen["ua"] == ingest.USER_AGENT
