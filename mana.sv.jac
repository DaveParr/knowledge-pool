"""Mana analysis: land count, coloured pips and coloured sources.

A pip is counted once per WUBRG letter named inside each `{...}` symbol in a
mana cost, so a hybrid symbol like {W/U} adds one pip to both W and U, and a
Phyrexian symbol like {W/P} adds one pip to W. Generic numbers, {X}, {C} and
{S} add no pips. A source is a card whose `produced_mana` lists that colour
(from MTGJSON, stored at ingest; see `catalog/ingest.py`).

The curve buckets non-land cards by mana value (0..6, 7+).

Every analysis here is a pure function of a deck's card lines (see
`card_lines.sv.jac`) and counts only the main deck (`main_deck`): the
sideboard is not part of the game's starting mana base. A land is
`CardLine.is_land`, the same for the land count and the curve.
"""

import re;
import from card_lines { CardLine, main_deck }

glob COLOURS: list[str] = ["W", "U", "B", "R", "G"];

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

"""Lands, pips and sources across a deck's main deck."""
def mana_profile(lines: list[CardLine]) -> ManaProfile {
    pips: dict[str, int] = {};
    sources: dict[str, int] = {};
    for c in COLOURS {
        pips[c] = 0;
        sources[c] = 0;
    }
    land_count = 0;
    for line in main_deck(lines) {
        if line.is_land() {
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

glob CURVE_BUCKETS: list[str] = ["0", "1", "2", "3", "4", "5", "6", "7+"];

"""Non-land mana-value buckets (0..6, 7+) over a deck's main deck, by card count,
plus the average non-land mana value."""
obj ManaCurve {
    has buckets: dict[str, int] = {},
        average_mv: float = 0.0;
}

def bucket_for(mv: float) -> str {
    n = int(mv);
    return "7+" if n >= 7 else str(max(n, 0));
}

"""The non-land curve of a deck's main deck."""
def mana_curve(lines: list[CardLine]) -> ManaCurve {
    buckets: dict[str, int] = {b: 0 for b in CURVE_BUCKETS};
    total_mv = 0.0;
    total_count = 0;
    for line in main_deck(lines) {
        if line.is_land() {
            continue;
        }
        buckets[bucket_for(line.mana_value)] += line.count;
        total_mv += line.mana_value * line.count;
        total_count += line.count;
    }
    avg: float = 0.0;
    if total_count > 0 {
        raw: float = total_mv / total_count;
        scaled: float = round(raw * 100);
        avg = scaled / 100.0;
    }
    return ManaCurve(buckets=buckets, average_mv=avg);
}
