"""Ingest of the MTGJSON fixture, and search over the result."""

import json
import time

from catalog import store
from catalog.ingest import load_oracle_tags, main


def test_meta_records_mtgjson_version_and_date():
    meta = store.meta()
    assert meta["mtgjson_version"] == "5.3.0+fixture"
    assert meta["mtgjson_date"] == "2026-01-01"
    assert meta["ingested_at"]
    assert meta["card_count"] == "35"


def test_one_row_per_oracle_card_with_its_fields():
    bolt = store.search("lightning bolt")[0]
    assert bolt["name"] == "Lightning Bolt"
    assert bolt["mana_value"] == 1.0
    assert bolt["colour_identity"] == ["R"]
    assert bolt["types"] == ["Instant"]
    assert bolt["legal"]["modern"] == "Legal"
    assert bolt["produced_mana"] == []
    assert store.get_card(bolt["oracle_id"])["name"] == "Lightning Bolt"


def test_oracle_tags_present_after_ingest_on_lookup_and_search():
    bolt = store.get_card("4457ed35-7c10-48c8-9776-456485fdf070")
    assert sorted(bolt["oracle_tags"]) == ["burn", "removal"]

    hit = store.search("lightning bolt")[0]
    assert sorted(hit["oracle_tags"]) == ["burn", "removal"]

    # A card with no taggings in the fixture gets an empty list, not an error.
    mountain = store.find_by_name("Mountain")
    assert mountain["oracle_tags"] == []


def test_load_oracle_tags_resolves_parent_ids_to_parent_slugs():
    from tests.conftest import TAGS_FIXTURE

    tag_rows, card_tag_rows = load_oracle_tags(TAGS_FIXTURE)
    by_slug = {slug: (description, json.loads(parents)) for slug, description, parents in tag_rows}

    assert by_slug["removal"] == ("Cards that remove a permanent.", [])
    # A null description becomes "", not None (the tags table is NOT NULL).
    assert by_slug["removal-creature"] == ("", ["removal"])

    assert ("4457ed35-7c10-48c8-9776-456485fdf070", "removal") in card_tag_rows
    assert ("51d9564b-44fc-4de1-9119-09d7b4089378", "removal-creature") in card_tag_rows


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


def test_creature_stats_and_keywords_are_stored_from_mtgjson():
    guide = store.find_by_name("Goblin Guide")
    assert (guide["power"], guide["toughness"]) == ("2", "2")
    assert guide["keywords"] == ["Haste"]
    assert guide["loyalty"] == guide["defense"] == ""
    assert guide["faces"] == []  # one face: the row holds it all
    bolt = store.find_by_name("Lightning Bolt")
    assert (bolt["power"], bolt["toughness"], bolt["keywords"]) == ("", "", [])


def test_planeswalker_loyalty_and_battle_defence_are_stored():
    jace = store.find_by_name("Jace, the Mind Sculptor")
    assert jace["loyalty"] == "3"
    assert jace["power"] == ""
    invasion = store.find_by_name("Invasion of Tarkir")
    assert invasion["defense"] == "5"
    assert invasion["power"] == ""  # the front face is a battle; the back is the 4/4


def test_multi_face_card_keeps_each_face_with_its_own_cost_type_text_and_stats():
    delver = store.find_by_name("Delver of Secrets")
    assert (delver["power"], delver["toughness"]) == ("1", "1")  # front face
    assert delver["keywords"] == ["Flying", "Transform"]
    front, back = delver["faces"]
    assert front == {
        "name": "Delver of Secrets", "mana_cost": "{U}", "type_line": "Creature \u2014 Human Wizard",
        "text": front["text"], "power": "1", "toughness": "1", "loyalty": "", "defense": "",
    }
    assert front["text"].startswith("At the beginning of your upkeep")
    assert back == {
        "name": "Insectile Aberration", "mana_cost": "", "type_line": "Creature \u2014 Human Insect",
        "text": "Flying", "power": "3", "toughness": "2", "loyalty": "", "defense": "",
    }
    fire, ice = store.find_by_name("Fire // Ice")["faces"]
    assert (fire["name"], fire["mana_cost"], ice["name"], ice["mana_cost"]) == ("Fire", "{1}{R}", "Ice", "{1}{U}")


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
    from tests.conftest import FIXTURE, TAGS_FIXTURE

    out = tmp_path / "cli.sqlite"
    assert main(["--source", str(FIXTURE), "--tags-source", str(TAGS_FIXTURE), "--out", str(out)]) == 0
    assert "35 cards from MTGJSON 5.3.0+fixture (2026-01-01) and 3 Scryfall oracle tags" in capsys.readouterr().out
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


def test_download_oracle_tags_sends_a_user_agent_and_follows_the_bulk_index(tmp_path, monkeypatch):
    """Scryfall, like MTGJSON, returns 403 to Python's default user agent."""
    import io
    import json
    import urllib.request

    from catalog import ingest

    seen = {"ua": []}
    index = {
        "data": [
            {"type": "oracle_cards", "download_uri": "https://data.scryfall.io/oracle-cards.json"},
            {"type": "oracle_tags", "jsonl_download_uri": "https://data.scryfall.io/oracle-tags.jsonl.gz"},
        ]
    }

    def fake_urlopen(req, timeout=None):
        seen["ua"].append(req.get_header("User-agent"))
        if req.full_url == ingest.SCRYFALL_BULK_DATA_URL:
            return io.BytesIO(json.dumps(index).encode())
        assert req.full_url == "https://data.scryfall.io/oracle-tags.jsonl.gz"
        return io.BytesIO(b"tags-data")

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    dest = ingest.download_oracle_tags(tmp_path / "oracle-tags.jsonl.gz")
    assert dest.read_bytes() == b"tags-data"
    assert seen["ua"] == [ingest.USER_AGENT, ingest.USER_AGENT]
