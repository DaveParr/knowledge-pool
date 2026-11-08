"""Unit tests for mana pip-counting and the main-deck mana profile."""

import from mana { count_pips }

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
