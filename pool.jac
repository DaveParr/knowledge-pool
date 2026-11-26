"""The pool gradient for one deck: its colour identity, as the mana tints in WUBRG order.

Pool block fills the deck header, the mana tiles' caps, the curve bars and the primary
action with a gradient that follows the deck it belongs to (`DeckView.colours`, from
`deck_colours`). A mono-coloured deck runs its colour into paper and a colourless one
runs `--mana-c` into paper; off a deck, global.css's default is all five colours.
The MCP views build the same gradient in ui/pool.html.
"""

"""The gradient's colour stops for a deck's colours ("W", "U", "B", "R", "G")."""
def poolStops(colours: list[str]) -> list[str] {
    tints = ["var(--mana-" + c.lower() + ")" for c in colours];
    if len(tints) == 0 {
        return ["var(--mana-c)", "var(--pool-paper)"];
    }
    if len(tints) == 1 {
        return [tints[0], "var(--pool-paper)"];
    }
    return tints;
}

"""Inline style that sets `--pool` (across, for headers and buttons) and `--pool-down`
(top to bottom, for curve bars) for everything inside the element."""
def poolStyle(colours: list[str]) -> dict[str, str] {
    stops = ", ".join(poolStops(colours));
    return {
        "--pool": "linear-gradient(110deg, " + stops + ")",
        "--pool-down": "linear-gradient(180deg, " + stops + ")"
    };
}
