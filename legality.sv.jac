"""Deck legality for 60-card constructed formats.

Each format's deck-construction rules live on a `Format` node. Whether a card
may be played at all comes from MTGJSON's per-card legalities. Whether a deck
is legal is always worked out here, on demand; it is never stored.
"""

import re;

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

"""A card line as the validator sees it."""
obj Entry {
    has name: str,
        zone: str,
        count: int,
        type_line: str,
        text: str,
        status: str;
}

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

"""How many copies of this card a deck may hold, or None for no limit."""
def copy_limit_for(line: Entry, fmt: Format) -> int | None {
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
    if line.status == "Restricted" {
        return 1;
    }
    return fmt.copy_limit;
}

"""Check a deck's card lines against a format. Pure function of its inputs."""
def check_entries(entries: list[Entry], fmt: Format) -> list[Violation] {
    found: list[Violation] = [];
    main_total = sum([e.count for e in entries if e.zone == "main"]);
    side_total = sum([e.count for e in entries if e.zone == "sideboard"]);
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
    first: dict[str, Entry] = {};
    for e in entries {
        totals[e.name] = totals.get(e.name, 0) + e.count;
        if e.name not in first {
            first[e.name] = e;
        }
    }
    for name in sorted(totals.keys()) {
        e = first[name];
        if e.status == "Banned" {
            found.append(Violation(rule="banned", message=f"{name} is banned in {fmt.label}.", card=name));
        } elif e.status not in ["Legal", "Restricted"] {
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
