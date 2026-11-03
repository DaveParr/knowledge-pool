import json
from pathlib import Path

import jsonschema
import pytest

from deckformats import ExportDeck, ExportEntry, get_format

SCHEMA = json.loads((Path(__file__).parent.parent / "schemas" / "mtgdeck-1.schema.json").read_text())


def test_schema_file_is_a_valid_json_schema():
    jsonschema.Draft202012Validator.check_schema(SCHEMA)


def _sample_deck() -> ExportDeck:
    return ExportDeck(
        name="Izzet Spells",
        format="pioneer",
        entries=[
            ExportEntry(oracle_id="o1", name="Ledger Shredder", count=4, zone="main", role="threat", tags=["spells-matter"], locked=True),
            ExportEntry(oracle_id="o2", name="Consider", count=4, zone="main", reason="cantrip"),
            ExportEntry(oracle_id="o3", name="Unlicensed Hearse", count=2, zone="sideboard"),
            ExportEntry(oracle_id="o4", name="Atraxa, Grand Unifier", count=1, zone="commander"),
        ],
    )


def test_render_mtgdeck1_validates_against_the_schema():
    import json

    doc = json.loads(get_format("mtgdeck1").render(_sample_deck()))
    jsonschema.validate(doc, SCHEMA)
    assert doc["schema"] == "mtgdeck/1"
    assert {e["name"] for e in doc["zones"]["main"]} == {"Ledger Shredder", "Consider"}


def test_parse_mtgdeck1_round_trips_every_field():
    fmt = get_format("mtgdeck1")
    parsed = fmt.parse(fmt.render(_sample_deck()))
    by_name = {e.raw_name: e for e in parsed.entries}
    assert by_name["Ledger Shredder"].count == 4
    assert by_name["Ledger Shredder"].zone == "main"
    assert by_name["Ledger Shredder"].role == "threat"
    assert by_name["Ledger Shredder"].tags == ["spells-matter"]
    assert by_name["Ledger Shredder"].locked is True
    assert by_name["Ledger Shredder"].oracle_id == "o1"
    assert by_name["Atraxa, Grand Unifier"].zone == "commander"
    assert by_name["Consider"].reason == "cantrip"


def test_get_format_rejects_unknown_name():
    with pytest.raises(ValueError, match="Unknown deck format"):
        get_format("not-a-format")


def test_render_mtgjson_groups_entries_by_zone():
    doc = json.loads(get_format("mtgjson").render(_sample_deck()))
    assert {e["name"]: e["count"] for e in doc["mainBoard"]} == {"Ledger Shredder": 4, "Consider": 4}
    assert {e["name"]: e["count"] for e in doc["sideBoard"]} == {"Unlicensed Hearse": 2}
    assert {e["name"]: e["count"] for e in doc["commander"]} == {"Atraxa, Grand Unifier": 1}


def test_mtgjson_does_not_support_import():
    with pytest.raises(NotImplementedError):
        get_format("mtgjson").parse("anything")


@pytest.mark.parametrize("name", ["text", "arena", "moxfield"])
def test_round_trips_a_simple_main_and_sideboard_list(name):
    deck = ExportDeck(name="d", format="modern", entries=[
        ExportEntry(oracle_id="o1", name="Lightning Bolt", count=4, zone="main"),
        ExportEntry(oracle_id="o2", name="Mountain", count=20, zone="main"),
        ExportEntry(oracle_id="o3", name="Negate", count=2, zone="sideboard"),
    ])
    fmt = get_format(name)
    parsed = fmt.parse(fmt.render(deck))
    assert {(e.raw_name, e.count, e.zone) for e in parsed.entries} == {
        ("Lightning Bolt", 4, "main"), ("Mountain", 20, "main"), ("Negate", 2, "sideboard"),
    }


def test_arena_strips_the_set_and_collector_number_suffix():
    parsed = get_format("arena").parse("4 Lightning Bolt (M10) 146\n")
    assert parsed.entries[0].raw_name == "Lightning Bolt"
    assert parsed.entries[0].count == 4


def test_a_line_that_is_not_count_and_name_is_unparsed_not_dropped():
    parsed = get_format("text").parse("4 Lightning Bolt\nthis is not a deck line\n")
    assert parsed.unparsed == ["this is not a deck line"]
    assert len(parsed.entries) == 1
