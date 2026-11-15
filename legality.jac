"""Deck legality for 60-card constructed formats and Commander.

Each format's deck-construction rules live on a `Format` node. Whether a card
may be played at all comes from MTGJSON's per-card legalities. Whether a deck
is legal is always worked out here, on demand; it is never stored.
"""

import re;
import from card_lines { CardLine, main_deck }
import from commander { DECK_ZONES, CHECKED_ZONES, commanders, can_lead, identity, identity_label, commander_names, partner_abilities, is_background, pair_problem }
import from walker_errors { WalkerError }

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
    "modern": "Modern",
    "commander": "Commander"
};

"""Per-format overrides of the Format defaults. For Commander, `min_main` is
the exact deck size over the commander zone and main deck."""
glob FORMAT_RULES: dict[str, dict[str, int]] = {
    "commander": {"min_main": 100, "copy_limit": 1, "sideboard_max": 0}
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
            fmt = Format(name=key, label=label, **FORMAT_RULES.get(key, {}));
            home ++> fmt;
            found.append(fmt);
        }
    }
    return found;
}

"""Every Format node under `home` (the guest's root), open to every user for
reading. The guest calls it before any user call, so no user ever makes one."""
def open_formats(home: Root) {
    for f in format_nodes(home) {
        grant(f, level=AccessLevel.READ);
    }
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

"""Check a deck's card lines against a format. Constructed formats count only LEGALITY_ZONES;
Commander goes to check_commander, which counts its own zones."""
def check_lines(lines: list[CardLine], fmt: Format) -> list[Violation] {
    if fmt.name == "commander" {
        return check_commander(lines, fmt);
    }
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
    return found + card_rule_violations(entries, fmt);
}

"""The per-card rules: banned, not-legal and copy-limit. Status is checked for
every entry; copies are counted only over lines in `copy_zones`."""
def card_rule_violations(entries: list[CardLine], fmt: Format, copy_zones: list[str] = LEGALITY_ZONES) -> list[Violation] {
    found: list[Violation] = [];
    totals: dict[str, int] = {};
    first: dict[str, CardLine] = {};
    for e in entries {
        totals[e.name] = totals.get(e.name, 0);
        if e.zone in copy_zones {
            totals[e.name] += e.count;
        }
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

"""Check a Commander deck: exact size over the commander zone and main deck,
singleton, banlist, and one eligible commander."""
def check_commander(lines: list[CardLine], fmt: Format) -> list[Violation] {
    found: list[Violation] = [];
    total = sum([l.count for l in lines if l.zone in DECK_ZONES]);
    if total != fmt.min_main {
        found.append(
            Violation(
                rule="deck-size",
                message=f"Deck has {total} cards counting the commander; {fmt.label} needs exactly {fmt.min_main}."
            )
        );
    }
    checked = [l for l in lines if l.zone in CHECKED_ZONES];
    found += card_rule_violations(checked, fmt, DECK_ZONES);
    cmdrs = commanders(lines);
    n = sum([l.count for l in cmdrs]);
    if n == 0 {
        found.append(
            Violation(
                rule="commander-count",
                message="A Commander deck needs a commander: put one in the commander zone."
            )
        );
    } elif n >= 3 {
        found.append(
            Violation(
                rule="commander-count",
                message=f"The commander zone holds {n} cards; {fmt.label} allows one, or two that pair."
            )
        );
    }
    paired = len(cmdrs) == 2 and n == 2;
    if paired {
        why = pair_problem(cmdrs[0], cmdrs[1]);
        if why {
            found.append(
                Violation(
                    rule="commander-pair",
                    message=f"{cmdrs[0].name} and {cmdrs[1].name} can't be commanders together: {why}."
                )
            );
        }
    }
    for (i, c) in enumerate(cmdrs) {
        if paired and is_background(c) and "choose a background" in partner_abilities(cmdrs[1 - i]) {
            continue;
        }
        if not can_lead(c) {
            found.append(
                Violation(
                    rule="commander-eligible",
                    message=f"{c.name} can't be your commander: MTGJSON doesn't list it as one (a legendary creature, or a card that says it can be your commander).",
                    card=c.name
                )
            );
        }
    }
    if 1 <= n and n <= 2 {
        allowed = identity(cmdrs);
        for l in lines {
            if l.zone in ["main", "companion"] {
                outside = [c for c in l.colour_identity if c not in allowed];
                if outside {
                    found.append(
                        Violation(
                            rule="colour-identity",
                            message=f"{l.name} ({identity_label(l.colour_identity)}) is outside {commander_names(cmdrs)}'s identity ({identity_label(allowed)})",
                            card=l.name
                        )
                    );
                }
            }
        }
    }
    return found;
}

"""The error for a play format that FORMAT_LABELS does not know."""
def unknown_format(format: str) -> WalkerError {
    return WalkerError(
        code="unknown-format", message=f"Unknown format {format}. Use one of: {', '.join(FORMAT_LABELS)}."
    );
}

"""A format's deck-construction rules, as reported to MCP clients."""
obj FormatRules {
    has name: str,
        label: str,
        min_main: int,
        copy_limit: int,
        sideboard_max: int,
        exact_size: bool = False,
        notes: list[str] = [];
}

"""The human-readable construction notes for a format."""
def format_notes(fmt: Format) -> list[str] {
    if fmt.name == "commander" {
        return [
            "Exactly 100 cards, counting the commander zone and the main deck. Companion and sideboard are not counted.",
            "Singleton: one copy of each card across the commander zone and main deck. Basic lands, and cards that say a deck can have any number (or up to N) of them, are exempt.",
            "The commander must be able to lead per MTGJSON leadershipSkills.commander. Two commanders are allowed when they pair: Partner, Partner with (each other), Partner—<same quality> such as Friends forever, Choose a Background with a Background, or Doctor's companion with a Time Lord Doctor.",
            "Every card in the commander zone, companion and main deck must be legal in Commander according to MTGJSON.",
            "Every card in the main deck and companion must fit inside the commander's colour identity (both commanders' together, for a pair)."
        ];
    }
    return [
        "The copy limit counts main deck and sideboard together.",
        "Basic lands, and cards that say a deck can have any number of them, have no copy limit.",
        "Cards that say a deck can have up to N of them use N instead.",
        f"Every card must be legal in {fmt.label} according to MTGJSON; banned and not-legal cards are violations."
    ];
}

"""Report the rules for one format. An unknown format reports an
unknown-format WalkerError."""
walker GetFormatRules {
    has format: str,
        reports: list[FormatRules | WalkerError] = [];

    can show with Root entry {
        fmt = format_node(root.shared, self.format);
        if fmt is None {
            report unknown_format(self.format);
            disengage;
        }
        report FormatRules(
            name=fmt.name,
            label=fmt.label,
            min_main=fmt.min_main,
            copy_limit=fmt.copy_limit,
            sideboard_max=fmt.sideboard_max,
            exact_size=fmt.name == "commander",
            notes=format_notes(fmt)
        );
    }
}
