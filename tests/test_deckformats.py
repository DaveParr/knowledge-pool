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
