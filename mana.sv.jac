"""Mana analysis: land count, coloured pips and coloured sources.

A pip is counted once per WUBRG letter named inside each `{...}` symbol in a
mana cost, so a hybrid symbol like {W/U} adds one pip to both W and U, and a
Phyrexian symbol like {W/P} adds one pip to W. Generic numbers, {X}, {C} and
{S} add no pips. A source is a card whose `produced_mana` lists that colour
(from MTGJSON, stored at ingest; see `catalog/ingest.py`).

Only the main deck counts towards any of this - the sideboard is not part of
the game's starting mana base, matching how `legality.sv.jac` treats
`min_main`/`sideboard_max` as a separate, main-deck-only concern.
"""

import re;

glob COLOURS: list[str] = ["W", "U", "B", "R", "G"];

"""One main-deck card line, as the mana analyser sees it."""
obj ManaLine {
    has count: int,
        is_land: bool,
        mana_cost: str,
        produced_mana: list[str];
}

"""Lands, coloured pips (spell demand) and coloured sources (mana supply) for
a deck. `pips` and `sources` always carry all five WUBRG keys, zero when
absent."""
obj ManaProfile {
    has land_count: int = 0,
        pips: dict[str, int] = {},
        sources: dict[str, int] = {};
}

"""Pips contributed by one mana cost string, one entry per WUBRG colour."""
def count_pips(mana_cost: str) -> dict[str, int] {
    found: dict[str, int] = {};
    for c in COLOURS {
        found[c] = 0;
    }
    symbols: list[str] = re.findall(r"\{([^}]+)\}", mana_cost) as list[str];
    for symbol in symbols {
        for part in symbol.split("/") {
            if part in found {
                found[part] += 1;
            }
        }
    }
    return found;
}

"""Lands, pips and sources across a deck's main-deck lines. Pure function of its input."""
def mana_profile(lines: list[ManaLine]) -> ManaProfile {
    pips: dict[str, int] = {};
    sources: dict[str, int] = {};
    for c in COLOURS {
        pips[c] = 0;
        sources[c] = 0;
    }
    land_count = 0;
    for line in lines {
        if line.is_land {
            land_count += line.count;
        }
        for (colour, n) in count_pips(line.mana_cost).items() {
            pips[colour] += n * line.count;
        }
        for colour in line.produced_mana {
            if colour in sources {
                sources[colour] += line.count;
            }
        }
    }
    return ManaProfile(land_count=land_count, pips=pips, sources=sources);
}
