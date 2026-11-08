"""Deck legality for 60-card constructed formats.

Each format's deck-construction rules live on a `Format` node. Whether a card
may be played at all comes from MTGJSON's per-card legalities. Whether a deck
is legal is always worked out here, on demand; it is never stored.
"""

import re;
import from card_lines { CardLine, main_deck }

"""Deck-construction rules for one format."""
node Format {
    has name: str,
        label: str,
        min_main: int = 60,
        copy_limit: int = 4,
        sideboard_max: int = 15;
}

"""The formats we check, keyed by MTGJSON's legality key."""
glob FORMAT_LABELS: dict[str, str] = {
    "standard": "Standard",
    "pioneer": "Pioneer",
    "modern": "Modern"
};

"""One rule a deck breaks."""
obj Violation {
    has rule: str,
        message: str,
        card: str = "";
}

"""The zones legality counts: the main deck and the sideboard. Commander,
companion and maybeboard are not part of a 60-card constructed deck."""
glob LEGALITY_ZONES: list[str] = ["main", "sideboard"];

glob NUMBER_WORDS: dict[str, int] = {
    "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
    "eight": 8, "nine": 9, "ten": 10
};

def cards(n: int) -> str {
    return f"{n} card" if n == 1 else f"{n} cards";
}

"""All Format nodes, created under `home` on first use."""
def format_nodes(home: Root) -> list[Format] {
    found = [home-->[?:Format]];
    have = [f.name for f in found];
    for (key, label) in FORMAT_LABELS.items() {
        if key not in have {
            fmt = Format(name=key, label=label);
            home ++> fmt;
            found.append(fmt);
        }
    }
    return found;
}

def format_node(home: Root, key: str) -> Format | None {
    for f in format_nodes(home) {
        if f.name == key {
            return f;
        }
    }
    return None;
}

"""A card's MTGJSON legality status in a format ("Legal", "Banned", ...)."""
def status_in(line: CardLine, fmt: Format) -> str {
    return line.legal.get(fmt.name, "Not legal");
}

"""How many copies of this card a deck may hold, or None for no limit."""
def copy_limit_for(line: CardLine, fmt: Format) -> int | None {
    if "Basic" in line.type_line and "Land" in line.type_line {
        return None;
    }
    if "A deck can have any number of cards named" in line.text {
        return None;
    }
    m = re.search(r"A deck can have up to (\w+) cards named", line.text);
    if m is not None {
        word = m.group(1).lower();
        if word in NUMBER_WORDS {
            return NUMBER_WORDS[word];
        }
        if word.isdigit() {
            return int(word);
        }
    }
    if status_in(line, fmt) == "Restricted" {
        return 1;
    }
    return fmt.copy_limit;
}

"""Check a deck's card lines against a format. Only LEGALITY_ZONES count."""
def check_lines(lines: list[CardLine], fmt: Format) -> list[Violation] {
    found: list[Violation] = [];
    entries = [l for l in lines if l.zone in LEGALITY_ZONES];
    main_total = sum([l.count for l in main_deck(entries)]);
    side_total = sum([l.count for l in entries if l.zone == "sideboard"]);
    if main_total < fmt.min_main {
        found.append(
            Violation(
                rule="main-deck-size",
                message=f"Main deck has {cards(main_total)}; {fmt.label} needs at least {fmt.min_main}."
            )
        );
    }
    if side_total > fmt.sideboard_max {
        found.append(
            Violation(
                rule="sideboard-size",
                message=f"Sideboard has {cards(side_total)}; {fmt.label} allows at most {fmt.sideboard_max}."
            )
        );
    }
    totals: dict[str, int] = {};
    first: dict[str, CardLine] = {};
    for e in entries {
        totals[e.name] = totals.get(e.name, 0) + e.count;
        if e.name not in first {
            first[e.name] = e;
        }
    }
    for name in sorted(totals.keys()) {
        e = first[name];
        status = status_in(e, fmt);
        if status == "Banned" {
            found.append(Violation(rule="banned", message=f"{name} is banned in {fmt.label}.", card=name));
        } elif status not in ["Legal", "Restricted"] {
            found.append(Violation(rule="not-legal", message=f"{name} is not legal in {fmt.label}.", card=name));
        }
        limit = copy_limit_for(e, fmt);
        if limit is not None and totals[name] > limit {
            found.append(
                Violation(
                    rule="copy-limit",
                    message=f"{totals[name]} copies of {name}; {fmt.label} allows {limit}.",
                    card=name
                )
            );
        }
    }
    return found;
}

"""A format's deck-construction rules, as reported to MCP clients."""
obj FormatRules {
    has name: str,
        label: str,
        min_main: int,
        copy_limit: int,
        sideboard_max: int,
        notes: list[str] = [];
}

"""Report the rules for one format (nothing if the format is unknown)."""
walker GetFormatRules {
    has format: str,
        reports: list[FormatRules] = [];

    can show with Root entry {
        fmt = format_node(here, self.format);
        if fmt is None {
            disengage;
        }
        report FormatRules(
            name=fmt.name,
            label=fmt.label,
            min_main=fmt.min_main,
            copy_limit=fmt.copy_limit,
            sideboard_max=fmt.sideboard_max,
            notes=[
                "The copy limit counts main deck and sideboard together.",
                "Basic lands, and cards that say a deck can have any number of them, have no copy limit.",
                "Cards that say a deck can have up to N of them use N instead.",
                f"Every card must be legal in {fmt.label} according to MTGJSON; banned and not-legal cards are violations."
            ]
        );
    }
}
