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
            ExportEntry(oracle_id="o1", name="Ledger Shredder", count=4, zone="main", roles=["threat"], tags=["spells-matter"], locked=True),
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
    assert by_name["Ledger Shredder"].roles == ["threat"]
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


MTGJSON_DECKS = Path(__file__).parent / "fixtures" / "mtgjson_decks"


def _zone_counts(parsed) -> dict[str, int]:
    totals: dict[str, int] = {}
    for e in parsed.entries:
        totals[e.zone] = totals.get(e.zone, 0) + e.count
    return totals


def test_parse_mtgjson_reads_a_real_commander_precon_file():
    parsed = get_format("mtgjson").parse((MTGJSON_DECKS / "TemurRoar_TDC.json").read_text())
    assert (parsed.name, parsed.format) == ("Temur Roar", "commander")
    assert _zone_counts(parsed) == {"commander": 1, "main": 99}
    [commander] = [e for e in parsed.entries if e.zone == "commander"]
    assert commander.raw_name == "Eshki, Temur's Roar"
    assert commander.oracle_id
    assert all(e.oracle_id for e in parsed.entries)
    assert parsed.unparsed == []


def test_parse_mtgjson_reads_a_real_challenger_deck_with_no_play_format():
    parsed = get_format("mtgjson").parse((MTGJSON_DECKS / "GruulStompy_Q07.json").read_text())
    assert (parsed.name, parsed.format) == ("Gruul Stompy", "")
    assert _zone_counts(parsed) == {"main": 60, "sideboard": 15}
    # Two printings of one card stay as two entries; resolve_list sums them.
    assert [e.count for e in parsed.entries if e.raw_name == "Kappa Tech-Wrecker"] == [1, 1]


def test_parse_mtgjson_accepts_a_bare_deck_object():
    doc = json.loads((MTGJSON_DECKS / "GruulStompy_Q07.json").read_text())
    fmt = get_format("mtgjson")
    bare = fmt.parse(json.dumps(doc["data"]))
    full = fmt.parse(json.dumps(doc))
    assert bare == full


def test_parse_mtgjson_maps_every_zone_we_export():
    doc = {
        "name": "Zones", "type": "Commander Deck",
        "commander": [{"name": "A", "count": 1}],
        "mainBoard": [{"name": "B", "count": 2}],
        "sideBoard": [{"name": "C", "count": 3}],
        "companion": [{"name": "D", "count": 1}],
        "maybeboard": [{"name": "E", "count": 4}],
    }
    parsed = get_format("mtgjson").parse(json.dumps(doc))
    assert {(e.raw_name, e.count, e.zone) for e in parsed.entries} == {
        ("A", 1, "commander"), ("B", 2, "main"), ("C", 3, "sideboard"), ("D", 1, "companion"), ("E", 4, "maybeboard"),
    }


def test_parse_mtgjson_notes_each_skipped_list_that_has_entries():
    doc = {
        "name": "Extras",
        "mainBoard": [{"name": "Forest", "count": 1, "identifiers": {"scryfallOracleId": "f"}}],
        "displayCommander": [{"name": "X", "count": 1}],
        "tokens": [{"name": "Beast", "count": 1}, {"name": "Saproling", "count": 2}, {"name": "Treasure", "count": 1}],
        "planes": [],
        "schemes": [{"name": "Y", "count": 1}],
    }
    parsed = get_format("mtgjson").parse(json.dumps(doc))
    assert [(e.raw_name, e.oracle_id) for e in parsed.entries] == [("Forest", "f")]
    assert parsed.unparsed == [
        "displayCommander (1 entry, not imported)",
        "tokens (3 entries, not imported)",
        "schemes (1 entry, not imported)",
    ]


def test_parse_mtgjson_skips_and_notes_bad_entries():
    doc = {"mainBoard": [
        {"name": "Good", "count": 2},
        {"count": 1},
        {"name": "Zero", "count": 0},
        {"name": "Flag", "count": True},
        "junk",
    ]}
    parsed = get_format("mtgjson").parse(json.dumps(doc))
    assert [(e.raw_name, e.count) for e in parsed.entries] == [("Good", 2)]
    assert parsed.unparsed == [
        "<unnamed> (invalid name)", "Zero (invalid count)", "Flag (invalid count)", "<unnamed> (invalid entry)",
    ]


@pytest.mark.parametrize("text", ["not json", "[]", '"deck"', '{"data": []}', '{"mainBoard": {}}'])
def test_parse_mtgjson_rejects_a_document_that_is_not_a_deck(text):
    with pytest.raises(ValueError, match="Not a valid MTGJSON deck"):
        get_format("mtgjson").parse(text)


def test_mtgjson_export_parses_back():
    fmt = get_format("mtgjson")
    parsed = fmt.parse(fmt.render(_sample_deck()))
    assert parsed.name == "Izzet Spells"
    assert {(e.raw_name, e.count, e.zone) for e in parsed.entries} == {
        ("Ledger Shredder", 4, "main"), ("Consider", 4, "main"),
        ("Unlicensed Hearse", 2, "sideboard"), ("Atraxa, Grand Unifier", 1, "commander"),
    }
    assert parsed.unparsed == []


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


# --- mtgdeck1 parse: malformed documents and invalid entries ---


@pytest.mark.parametrize("text", [
    "4 Lightning Bolt",
    "not json at all {",
    json.dumps(["a", "list"]),
    json.dumps({"schema": "mtgdeck/1", "zones": ["main"]}),
    json.dumps({"schema": "mtgdeck/1", "zones": {"main": {"name": "Mountain", "count": 1}}}),
    json.dumps({}),
    json.dumps({"schema": "mtgdeck/2", "name": "x", "zones": {}}),
    json.dumps({"name": "x", "mainBoard": [{"count": 4, "name": "Lightning Bolt"}]}),
])
def test_mtgdeck1_rejects_a_malformed_document_with_a_value_error(text):
    with pytest.raises(ValueError):
        get_format("mtgdeck1").parse(text)


def _mtgdeck1(*main_entries) -> str:
    return json.dumps({"schema": "mtgdeck/1", "name": "d", "format": "modern", "zones": {"main": list(main_entries)}})


@pytest.mark.parametrize("bad_entry, label", [
    ({"name": "Mountain", "count": -5}, "Mountain (invalid count)"),
    ({"name": "Mountain", "count": 0}, "Mountain (invalid count)"),
    ({"name": "Mountain", "count": "4"}, "Mountain (invalid count)"),
    ({"name": "Mountain", "count": 1.5}, "Mountain (invalid count)"),
    ({"name": "Mountain", "count": True}, "Mountain (invalid count)"),
    ({"name": "Mountain"}, "Mountain (invalid count)"),
    ({"count": 4}, "<unnamed> (invalid name)"),
    ({"name": "Mountain", "count": 1, "roles": "commander"}, "Mountain (invalid roles)"),
    ({"name": "Mountain", "count": 1, "roles": [1]}, "Mountain (invalid roles)"),
    ({"name": "Mountain", "count": 1, "tags": "burn"}, "Mountain (invalid tags)"),
    ({"name": "Mountain", "count": 1, "tags": ["ok", None]}, "Mountain (invalid tags)"),
    ("Mountain", "<unnamed> (invalid entry)"),
])
def test_mtgdeck1_skips_an_invalid_entry_but_keeps_the_rest(bad_entry, label):
    parsed = get_format("mtgdeck1").parse(_mtgdeck1(bad_entry, {"name": "Lightning Bolt", "count": 4}))
    assert [(e.raw_name, e.count) for e in parsed.entries] == [("Lightning Bolt", 4)]
    assert parsed.unparsed == [label]


# --- line lists: real-world headers ---


@pytest.mark.parametrize("name", ["text", "arena", "moxfield"])
def test_a_header_with_a_trailing_colon_is_recognized(name):
    parsed = get_format(name).parse("4 Lightning Bolt\n\nSideboard:\n2 Negate\n")
    assert parsed.unparsed == []
    assert {(e.raw_name, e.zone) for e in parsed.entries} == {("Lightning Bolt", "main"), ("Negate", "sideboard")}


def test_arena_deck_header_with_a_trailing_colon_is_recognized():
    parsed = get_format("arena").parse("Deck:\n4 Lightning Bolt\n")
    assert parsed.unparsed == []
    assert [(e.raw_name, e.zone) for e in parsed.entries] == [("Lightning Bolt", "main")]


@pytest.mark.parametrize("name", ["text", "arena", "moxfield"])
@pytest.mark.parametrize("commander_header, companion_header", [("Commander", "Companion"), ("commander:", "COMPANION:")])
def test_commander_and_companion_headers_route_to_their_zones(name, commander_header, companion_header):
    # Arena's "Deck" header switches back to main; text/moxfield have no main
    # header, so their main cards come first.
    special = f"{commander_header}\n1 Atraxa, Grand Unifier\n\n{companion_header}\n1 Lurrus of the Dream-Den\n"
    text = f"{special}\nDeck\n4 Lightning Bolt\n" if name == "arena" else f"4 Lightning Bolt\n\n{special}"
    parsed = get_format(name).parse(text)
    assert parsed.unparsed == []
    assert sorted((e.raw_name, e.zone) for e in parsed.entries) == [
        ("Atraxa, Grand Unifier", "commander"),
        ("Lightning Bolt", "main"),
        ("Lurrus of the Dream-Den", "companion"),
    ]


def test_moxfield_strips_the_set_and_collector_number_suffix():
    parsed = get_format("moxfield").parse("4 Lightning Bolt (2XM) 123\n")
    assert [(e.raw_name, e.count) for e in parsed.entries] == [("Lightning Bolt", 4)]


@pytest.mark.parametrize("name", ["text", "moxfield"])
@pytest.mark.parametrize("main_header", ["Deck", "Main", "Mainboard"])
def test_commander_first_paste_recognizes_a_built_in_main_header(name, main_header):
    # Regression: text/moxfield have no configured deck_header, so a
    # Commander-first paste (common in real Moxfield exports) used to have
    # no way back to "main" and silently re-zoned the whole main deck as
    # "commander".
    text = f"Commander\n1 Atraxa, Grand Unifier\n\n{main_header}\n4 Lightning Bolt\n20 Mountain\n"
    parsed = get_format(name).parse(text)
    assert parsed.unparsed == []
    assert sorted((e.raw_name, e.zone) for e in parsed.entries) == [
        ("Atraxa, Grand Unifier", "commander"),
        ("Lightning Bolt", "main"),
        ("Mountain", "main"),
    ]


@pytest.mark.parametrize("name", ["text", "moxfield"])
def test_commander_first_paste_with_no_main_header_still_mis_zones_main_deck(name):
    # Documented remaining gap (accepted out of scope for this fix round):
    # when the paste has NO explicit main-deck header at all between the
    # commander line and the main-deck lines, there is still no header to
    # switch back to "main" on, so the main deck is mis-zoned as "commander".
    text = "Commander\n1 Atraxa, Grand Unifier\n\n4 Lightning Bolt\n20 Mountain\n"
    parsed = get_format(name).parse(text)
    assert parsed.unparsed == []
    assert sorted((e.raw_name, e.zone) for e in parsed.entries) == [
        ("Atraxa, Grand Unifier", "commander"),
        ("Lightning Bolt", "commander"),
        ("Mountain", "commander"),
    ]


def test_every_offered_export_format_is_one_the_package_can_write():
    from deckformats import EXPORT_FORMATS, FORMATS, export_format_choices

    assert [f.key for f in EXPORT_FORMATS] == list(FORMATS)
    for choice in export_format_choices():
        fmt = get_format(choice["key"])
        assert fmt.render(_sample_deck()), choice["key"]
        assert choice["label"] and choice["ext"] in {"txt", "json"}
        assert isinstance(choice["lossless"], bool)


def test_no_view_keeps_its_own_list_of_zones():
    """Zones and their titles are listed once, in zones.jac."""
    root = Path(__file__).parent.parent
    for source in root.glob("*.jac"):
        if not source.is_file():
            continue
        if source.name in ("zones.jac", "legality.jac", "commander.jac"):
            continue
        text = source.read_text()
        assert '"companion", "main"' not in text, source.name
        assert '"Main deck"' not in text, source.name
