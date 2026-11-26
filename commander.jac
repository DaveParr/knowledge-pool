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

"""A deck's colours: the colour identity of its commander and main deck, in WUBRG
order (the sideboard and companion don't count). The pool gradient follows it."""
def deck_colours(lines: list[CardLine]) -> list[str] {
    return identity([l for l in lines if l.zone in DECK_ZONES]);
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

"""Every pairing ability on a card, in text order, read from its rules-text
lines (reminder text stripped): "partner", "partner with:<Name>",
"partner—<Quality>", "choose a background", "doctor's companion"."""
def partner_abilities(line: CardLine) -> list[str] {
    found: list[str] = [];
    for raw in line.text.split("\n") {
        t = raw.split(" (")[0].strip();
        if t == "Partner" {
            found.append("partner");
        } elif t.startswith("Partner with ") {
            found.append("partner with:" + t[len("Partner with "):]);
        } elif t.startswith("Partner—") {
            found.append("partner—" + t[len("Partner—"):]);
        } elif t == "Choose a Background" {
            found.append("choose a background");
        } elif t == "Doctor's companion" {
            found.append("doctor's companion");
        }
    }
    return found;
}

"""A card's first partner ability, or "" when it has none."""
def partner_ability(line: CardLine) -> str {
    found = partner_abilities(line);
    return found[0] if found else "";
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
    padded = " " + subs + " ";
    return "Creature" in front.split("—")[0].split(" ") and " Time Lord " in padded and " Doctor " in padded;
}

"""An ability as printed on the card ("partner—Friends forever" -> "Partner—Friends forever")."""
def _printed(ability: str) -> str {
    if ability.startswith("partner with:") {
        return "Partner with " + ability[len("partner with:"):];
    }
    return ability[0].upper() + ability[1:];
}

"""Whether one ability on x pairs with y."""
def _pairs_with(ab: str, x: CardLine, y: CardLine) -> bool {
    abs_y = partner_abilities(y);
    if ab == "partner" or ab.startswith("partner—") {
        return ab in abs_y;
    }
    if ab.startswith("partner with:") {
        return ab == "partner with:" + y.name and ("partner with:" + x.name) in abs_y;
    }
    if ab == "choose a background" {
        return is_background(y);
    }
    return is_time_lord_doctor(y);
}

"""The ability to name in a "don't pair" message: a partner-with aimed at
the other card, else the first."""
def _most_relevant(abilities: list[str], other: CardLine) -> str {
    if ("partner with:" + other.name) in abilities {
        return "partner with:" + other.name;
    }
    return abilities[0];
}

"""Why two cards can't be commanders together, or "" when they may be.
A card with several pairing abilities pairs if any of them does. The cards
are named in the order given."""
def pair_problem(a: CardLine, b: CardLine) -> str {
    ab_a = partner_abilities(a);
    ab_b = partner_abilities(b);
    for ab in ab_a {
        if _pairs_with(ab, a, b) {
            return "";
        }
    }
    for ab in ab_b {
        if _pairs_with(ab, b, a) {
            return "";
        }
    }
    for (x, y, abs_x) in [(a, b, ab_a), (b, a, ab_b)] {
        if "choose a background" in abs_x and not is_background(y) {
            return f"{x.name} needs a Background";
        }
    }
    for (x, y, abs_x) in [(a, b, ab_a), (b, a, ab_b)] {
        if "doctor's companion" in abs_x and not is_time_lord_doctor(y) {
            return f"{x.name} needs a Time Lord Doctor";
        }
    }
    for (x, abs_x, abs_y) in [(a, ab_a, ab_b), (b, ab_b, ab_a)] {
        matched = (is_background(x) and "choose a background" in abs_y) or (is_time_lord_doctor(x) and "doctor's companion" in abs_y);
        if not abs_x and not matched {
            return f"{x.name} has no partner ability";
        }
    }
    for (x, y, abs_x) in [(a, b, ab_a), (b, a, ab_b)] {
        for ab in abs_x {
            if ab.startswith("partner with:") and ab != "partner with:" + y.name {
                return f"{x.name} can only partner with {ab[len('partner with:'):]}";
            }
        }
    }
    return f"{_printed(_most_relevant(ab_a, b))} and {_printed(_most_relevant(ab_b, a))} don't pair";
}

"""Game Changers in a deck: their names (sorted), how many, and the bracket
that count suggests. A hint from Game Changers only, not a full bracket rating."""
obj GameChangers {
    has cards: list[str] = [],
        count: int = 0,
        bracket_hint: str = "";
}

"""The bracket suggested by a Game Changer count: 0 is 1-2, 1 to 3 is 3, 4 or more is 4+."""
def bracket_hint(count: int) -> str {
    if count == 0 {
        return "Bracket 1–2";
    }
    if count <= 3 {
        return "Bracket 3";
    }
    return "Bracket 4+";
}

"""The distinct Game Changers in the commander, companion and main zones."""
def game_changers(lines: list[CardLine]) -> GameChangers {
    names = sorted(list({l.name for l in lines if l.game_changer and l.zone in CHECKED_ZONES}));
    return GameChangers(cards=names, count=len(names), bracket_hint=bracket_hint(len(names)));
}
