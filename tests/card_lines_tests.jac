"""Tests for the card-line read model and the pure analysers over it:
legality, mana profile and curve. None of these need a graph."""

import from card_lines { CardLine, main_deck }
import from mana { mana_profile, mana_curve }
import from legality { Format, check_lines }

"""A card line with only the fields a test cares about."""
def _line(name: str, zone: str, count: int, type_line: str, mana_value: float = 0.0) -> CardLine {
    return CardLine(oracle_id=name, name=name, zone=zone, count=count, type_line=type_line, mana_value=mana_value);
}

test "a land is a card whose front face is a land" {
    assert _line("Mountain", "main", 1, "Basic Land — Mountain").is_land();
    assert _line("Dryad Arbor", "main", 1, "Land Creature — Forest Dryad").is_land();
    assert _line("Hengegate Pathway", "main", 1, "Land // Land").is_land();
    assert not _line("Lightning Bolt", "main", 1, "Instant").is_land();
}

test "a double-faced spell with a land back is a spell, for land count and curve alike" {
    valakut = _line("Valakut Awakening", "main", 1, "Sorcery // Basic Land — Mountain", 3.0);
    mountain = _line("Mountain", "main", 10, "Basic Land — Mountain");
    lines = [valakut, mountain];
    assert not valakut.is_land();
    assert mana_profile(lines).land_count == 10;
    assert mana_curve(lines).buckets["3"] == 1;
}

test "main deck is the main zone only" {
    lines = [
        _line("A", "main", 1, "Instant"),
        _line("B", "sideboard", 1, "Instant"),
        _line("C", "commander", 1, "Creature"),
        _line("D", "maybeboard", 1, "Instant")
    ];
    assert [l.name for l in main_deck(lines)] == ["A"];
}

test "mana curve buckets non-land main cards by mana value, weighted by count" {
    lines = [
        _line("Lightning Bolt", "main", 4, "Instant", 1.0),
        _line("Big Spell", "main", 1, "Sorcery", 9.0),
        _line("Mountain", "main", 20, "Basic Land — Mountain"),
        _line("Valakut Awakening", "main", 1, "Sorcery // Basic Land — Mountain", 3.0),
        _line("Fireball", "main", 1, "Sorcery", 0.0),
        _line("Lightning Bolt", "sideboard", 2, "Instant", 1.0)
    ];
    curve = mana_curve(lines);
    assert curve.buckets == {"0": 1, "1": 4, "2": 0, "3": 1, "4": 0, "5": 0, "6": 0, "7+": 1};
    assert curve.average_mv == 2.29;
}

test "mana curve is all zero with no non-land main cards" {
    curve = mana_curve([_line("Mountain", "main", 40, "Basic Land — Mountain")]);
    assert curve.buckets == {"0": 0, "1": 0, "2": 0, "3": 0, "4": 0, "5": 0, "6": 0, "7+": 0};
    assert curve.average_mv == 0.0;
}

test "mana profile counts lands and multiplies pips and sources by copies, main deck only" {
    lines = [
        CardLine(oracle_id="m", name="Mountain", zone="main", count=4, type_line="Basic Land — Mountain", produced_mana=["R"]),
        CardLine(oracle_id="i", name="Island", zone="main", count=4, type_line="Basic Land — Island", produced_mana=["U"]),
        CardLine(oracle_id="c", name="Izzet Charm", zone="main", count=2, type_line="Instant", mana_cost="{U}{R}"),
        CardLine(oracle_id="c", name="Izzet Charm", zone="sideboard", count=3, type_line="Instant", mana_cost="{U}{R}"),
        CardLine(oracle_id="s", name="Swamp", zone="sideboard", count=5, type_line="Basic Land — Swamp", produced_mana=["B"])
    ];
    profile = mana_profile(lines);
    assert profile.land_count == 8;
    assert profile.pips["U"] == 2;
    assert profile.pips["R"] == 2;
    assert profile.pips["W"] == 0;
    assert profile.sources["R"] == 4;
    assert profile.sources["U"] == 4;
    assert profile.sources["B"] == 0;
}

test "a card that produces an unrecognised colour letter is ignored" {
    lines = [CardLine(oracle_id="x", name="X", zone="main", count=1, produced_mana=["C"])];
    assert sum(mana_profile(lines).sources.values()) == 0;
}

test "legality counts main and sideboard, reads status for the format, ignores other zones" {
    fmt = Format(name="modern", label="Modern");
    legal = {"modern": "Legal"};
    lines = [
        CardLine(oracle_id="b", name="Bolt", zone="main", count=3, type_line="Instant", legal=legal),
        CardLine(oracle_id="b", name="Bolt", zone="sideboard", count=2, type_line="Instant", legal=legal),
        CardLine(oracle_id="m", name="Mountain", zone="main", count=57, type_line="Basic Land — Mountain", legal=legal),
        CardLine(oracle_id="o", name="Oko", zone="maybeboard", count=9, type_line="Planeswalker", legal={"modern": "Banned"}),
        CardLine(oracle_id="u", name="Unknown", zone="sideboard", count=1, type_line="Instant")
    ];
    rules = sorted([v.rule for v in check_lines(lines, fmt)]);
    assert rules == ["copy-limit", "not-legal"];
}
