"""Commander-specific helpers: which zones count for what, and who may lead.
The rules that use them live in `legality`."""

import from card_lines { CardLine }

"""Zones counted for deck size and singleton."""
glob DECK_ZONES: list[str] = ["commander", "main"];

"""Zones whose cards must be legal in Commander."""
glob CHECKED_ZONES: list[str] = ["commander", "companion", "main"];

"""The lines in the commander zone."""
def commanders(lines: list[CardLine]) -> list[CardLine] {
    return [l for l in lines if l.zone == "commander"];
}

"""Whether MTGJSON says this card can be your commander."""
def can_lead(line: CardLine) -> bool {
    return line.leadership.get("commander", False);
}

"""The five colours, in WUBRG order."""
glob COLOURS: list[str] = ["W", "U", "B", "R", "G"];

"""The union of the lines' colour identities, in WUBRG order."""
def identity(lines: list[CardLine]) -> list[str] {
    have: set[str] = set();
    for l in lines {
        have |= set(l.colour_identity);
    }
    return [c for c in COLOURS if c in have];
}

"""A colour identity as text: "colourless", or the letters ("R", "UR", "WUBG")."""
def identity_label(colours: list[str]) -> str {
    if not colours {
        return "colourless";
    }
    return "".join([c for c in COLOURS if c in colours]);
}

"""The commanders' names, joined with "and"."""
def commander_names(cmdrs: list[CardLine]) -> str {
    return " and ".join([c.name for c in cmdrs]);
}

"""A card's partner ability, read from its rules-text lines (reminder text
stripped): "partner", "partner with:<Name>", "partner—<Quality>",
"choose a background", "doctor's companion", or "" when it has none."""
def partner_ability(line: CardLine) -> str {
    for raw in line.text.split("\n") {
        t = raw.split(" (")[0].strip();
        if t == "Partner" {
            return "partner";
        }
        if t.startswith("Partner with ") {
            return "partner with:" + t[len("Partner with "):];
        }
        if t.startswith("Partner—") {
            return "partner—" + t[len("Partner—"):];
        }
        if t == "Choose a Background" {
            return "choose a background";
        }
        if t == "Doctor's companion" {
            return "doctor's companion";
        }
    }
    return "";
}

"""The subtypes on the front face's type line."""
def _front_subtypes(line: CardLine) -> str {
    front = line.type_line.split(" // ")[0];
    if "—" not in front {
        return "";
    }
    return front.split("—", 1)[1].strip();
}

"""Whether the card is a Background (a subtype of its front face)."""
def is_background(line: CardLine) -> bool {
    return "Background" in _front_subtypes(line).split(" ");
}

"""Whether the card is a Time Lord Doctor creature (front face)."""
def is_time_lord_doctor(line: CardLine) -> bool {
    front = line.type_line.split(" // ")[0];
    subs = _front_subtypes(line);
    return "Creature" in front.split("—")[0] and "Time Lord" in subs and "Doctor" in subs.split(" ");
}

"""An ability as printed on the card ("partner—Friends forever" -> "Partner—Friends forever")."""
def _printed(ability: str) -> str {
    return ability[0].upper() + ability[1:];
}

"""Why two cards can't be commanders together, or "" when they may be.
The cards are named in the order given."""
def pair_problem(a: CardLine, b: CardLine) -> str {
    ab_a = partner_ability(a);
    ab_b = partner_ability(b);
    for (x, y, ab) in [(a, b, ab_a), (b, a, ab_b)] {
        if ab == "choose a background" and not is_background(y) {
            return f"{x.name} needs a Background";
        }
    }
    for (x, y, ab) in [(a, b, ab_a), (b, a, ab_b)] {
        if ab == "doctor's companion" and not is_time_lord_doctor(y) {
            return f"{x.name} needs a Time Lord Doctor";
        }
    }
    for (x, ab, other) in [(a, ab_a, ab_b), (b, ab_b, ab_a)] {
        matched = (is_background(x) and other == "choose a background") or (is_time_lord_doctor(x) and other == "doctor's companion");
        if ab == "" and not matched {
            return f"{x.name} has no partner ability";
        }
    }
    for (x, y, ab) in [(a, b, ab_a), (b, a, ab_b)] {
        if ab.startswith("partner with:") and ab != "partner with:" + y.name {
            return f"{x.name} can only partner with {ab[len('partner with:'):]}";
        }
    }
    if ab_a == "" or ab_b == "" {
        return "";
    }
    if ab_a == ab_b and not ab_a.startswith("partner with:") {
        return "";
    }
    if ab_a.startswith("partner with:") and ab_b.startswith("partner with:") {
        return "";
    }
    return f"{_printed(ab_a)} and {_printed(ab_b)} don't pair";
}
