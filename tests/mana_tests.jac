"""Unit tests for mana pip-counting and the main-deck mana profile."""

import from mana { ManaLine, count_pips, mana_profile }

test "plain pips count once per coloured symbol" {
    pips = count_pips("{2}{W}{W}{U}");
    assert pips["W"] == 2;
    assert pips["U"] == 1;
    assert pips["B"] == 0;
}

test "hybrid symbol adds a pip to both named colours" {
    pips = count_pips("{W/U}");
    assert pips["W"] == 1;
    assert pips["U"] == 1;
}

test "phyrexian symbol adds a pip to its one named colour" {
    pips = count_pips("{B/P}");
    assert pips["B"] == 1;
    assert "P" not in pips;
}

test "generic numbers, X, colourless and snow add no pips" {
    pips = count_pips("{X}{2}{C}{S}");
    assert sum(pips.values()) == 0;
}

test "mana_profile counts lands and multiplies pips and sources by copies" {
    lines = [
        ManaLine(count=4, is_land=True, mana_cost="", produced_mana=["R"]),
        ManaLine(count=4, is_land=True, mana_cost="", produced_mana=["U"]),
        ManaLine(count=2, is_land=False, mana_cost="{U}{R}", produced_mana=[])
    ];
    profile = mana_profile(lines);
    assert profile.land_count == 8;
    assert profile.pips["U"] == 2;
    assert profile.pips["R"] == 2;
    assert profile.pips["W"] == 0;
    assert profile.sources["R"] == 4;
    assert profile.sources["U"] == 4;
    assert profile.sources["G"] == 0;
}

test "a card that produces an unrecognised colour letter is ignored" {
    lines = [ManaLine(count=1, is_land=False, mana_cost="", produced_mana=["C"])];
    profile = mana_profile(lines);
    assert sum(profile.sources.values()) == 0;
}
