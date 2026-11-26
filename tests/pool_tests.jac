"""Unit tests for the web app's pool gradient (pool.jac): the stops for a deck's colours."""

import from pool { poolStops, poolStyle }

test "two or more colours run their mana tints in the order given" {
    assert poolStops(["U", "R", "G"]) == ["var(--mana-u)", "var(--mana-r)", "var(--mana-g)"];
}

test "one colour runs into paper" {
    assert poolStops(["G"]) == ["var(--mana-g)", "var(--pool-paper)"];
}

test "colourless runs the colourless tint into paper" {
    assert poolStops([]) == ["var(--mana-c)", "var(--pool-paper)"];
}

test "the style sets --pool across and --pool-down top to bottom from the same stops" {
    style = poolStyle(["G"]);
    assert style["--pool"] == "linear-gradient(110deg, var(--mana-g), var(--pool-paper))";
    assert style["--pool-down"] == "linear-gradient(180deg, var(--mana-g), var(--pool-paper))";
}
