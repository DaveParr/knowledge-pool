"""Tests for the Commander format checks. None of these need a graph."""

import from card_lines { CardLine }
import from legality { Format, Violation, check_commander }
import from commander { can_lead, commanders, identity, identity_label, commander_names }

glob CMD: Format = Format(name="commander", label="Commander", min_main=100, copy_limit=1, sideboard_max=0);

"""A card line with only the fields a test cares about."""
def _line(
    name: str,
    zone: str,
    count: int,
    type_line: str = "Instant",
    legal: dict[str, str] = {"commander": "Legal"},
    leadership: dict[str, bool] = {},
    text: str = "",
    colour_identity: list[str] = []
) -> CardLine {
    return CardLine(
        oracle_id=name,
        name=name,
        zone=zone,
        count=count,
        type_line=type_line,
        legal=legal,
        leadership=leadership,
        text=text,
        colour_identity=colour_identity
    );
}

def _krenko() -> CardLine {
    return _line("Krenko, Mob Boss", "commander", 1, "Legendary Creature — Goblin", {"commander": "Legal"}, {"commander": True}, "", ["R"]);
}

def _basics(n: int) -> CardLine {
    return _line("Mountain", "main", n, "Basic Land — Mountain");
}

def _rules(vs: list[Violation]) -> list[str] {
    return [v.rule for v in vs];
}

test "a 100-card deck with an eligible commander is legal" {
    assert check_commander([_krenko(), _basics(99)], CMD) == [];
    assert can_lead(_krenko());
    assert [l.name for l in commanders([_krenko(), _basics(99)])] == ["Krenko, Mob Boss"];
}

test "deck size counts commander and main, not companion or sideboard" {
    lines = [
        _krenko(),
        _basics(98),
        _line("Lurrus of the Dream-Den", "companion", 1),
        _line("Shock", "sideboard", 5)
    ];
    vs = check_commander(lines, CMD);
    assert _rules(vs) == ["deck-size"];
    assert vs[0].message == "Deck has 99 cards counting the commander; Commander needs exactly 100.";
}

test "singleton counts commander and main; basics and any-number cards are exempt" {
    vs = check_commander([_krenko(), _line("Lightning Bolt", "main", 2), _basics(97)], CMD);
    assert _rules(vs) == ["copy-limit"];
    assert vs[0].message == "2 copies of Lightning Bolt; Commander allows 1.";
    rats = _line("Relentless Rats", "main", 20, "Creature — Rat", {"commander": "Legal"}, {}, "A deck can have any number of cards named Relentless Rats.");
    assert check_commander([_krenko(), _basics(60), rats, _line("Island", "main", 19, "Basic Land — Island")], CMD) == [];
}

test "a companion copy never makes a copy-limit" {
    lines = [_krenko(), _line("Shock", "main", 1), _line("Shock", "companion", 1), _basics(98)];
    assert check_commander(lines, CMD) == [];
}

test "banned is read from legal['commander'] across commander, companion and main" {
    base = [_krenko(), _basics(99)];
    bad = _line("Sol Ring", "companion", 1, "Artifact", {"commander": "Banned"});
    assert "banned" in _rules(check_commander(base + [bad], CMD));
    side = _line("Sol Ring", "sideboard", 1, "Artifact", {"commander": "Banned"});
    assert check_commander(base + [side], CMD) == [];
    nl = _line("Old Card", "main", 1, "Artifact", {"commander": "Not legal"});
    assert "not-legal" in _rules(check_commander([_krenko(), _basics(98), nl], CMD));
}

test "no commander is one commander-count violation" {
    vs = check_commander([_basics(100)], CMD);
    assert _rules(vs) == ["commander-count"];
    assert vs[0].message == "A Commander deck needs a commander: put one in the commander zone.";
}

test "two commanders are one commander-count violation" {
    vs = check_commander([_krenko(), _krenko(), _basics(98)], CMD);
    assert "commander-count" in _rules(vs);
    msgs = [v.message for v in vs if v.rule == "commander-count"];
    assert msgs == ["The commander zone holds 2 cards; Commander allows one."];
}

test "a planeswalker that can't lead is commander-eligible, naming the card" {
    jace = _line("Jace, the Mind Sculptor", "commander", 1, "Legendary Planeswalker — Jace");
    vs = check_commander([jace, _basics(99)], CMD);
    assert _rules(vs) == ["commander-eligible"];
    assert vs[0].card == "Jace, the Mind Sculptor";
    assert vs[0].message == "Jace, the Mind Sculptor can't be your commander: MTGJSON doesn't list it as one (a legendary creature, or a card that says it can be your commander).";
}

def _lead(name: str, colours: list[str]) -> CardLine {
    return _line(name, "commander", 1, "Legendary Creature — Human", {"commander": "Legal"}, {"commander": True}, "", colours);
}

test "identity unions colours in WUBRG order and labels them" {
    ls = [_line("A", "main", 1, "Instant", {"commander": "Legal"}, {}, "", ["G", "U"]), _line("B", "main", 1, "Instant", {"commander": "Legal"}, {}, "", ["W", "B"])];
    assert identity(ls) == ["W", "U", "B", "G"];
    assert identity_label([]) == "colourless";
    assert identity_label(["U", "R"]) == "UR";
    assert identity_label(identity(ls)) == "WUBG";
}

test "a card outside the commander's identity names the card and both identities" {
    bolt = _line("Counterspell", "main", 1, "Instant", {"commander": "Legal"}, {}, "", ["U"]);
    vs = check_commander([_krenko(), bolt, _basics(98)], CMD);
    assert _rules(vs) == ["colour-identity"];
    assert vs[0].message == "Counterspell (U) is outside Krenko, Mob Boss's identity (R)";
    assert vs[0].rule == "colour-identity" and vs[0].card == "Counterspell";
}

test "a colourless commander allows only colourless cards" {
    traxos = _lead("Traxos, Scourge of Kroog", []);
    ring = _line("Sol Ring", "main", 1, "Artifact");
    assert check_commander([traxos, ring, _line("Wastes", "main", 98, "Basic Land")], CMD) == [];
    bolt = _line("Lightning Bolt", "main", 1, "Instant", {"commander": "Legal"}, {}, "", ["R"]);
    vs = check_commander([traxos, bolt, _line("Wastes", "main", 98, "Basic Land")], CMD);
    assert vs[0].message == "Lightning Bolt (R) is outside Traxos, Scourge of Kroog's identity (colourless)";
}

test "the companion is checked like the main deck" {
    lutri = _line("Lutri, the Spellchaser", "companion", 1, "Legendary Creature", {"commander": "Legal"}, {}, "", ["U", "R"]);
    vs = check_commander([_krenko(), _basics(99), lutri], CMD);
    assert _rules(vs) == ["colour-identity"];
    assert vs[0].message == "Lutri, the Spellchaser (UR) is outside Krenko, Mob Boss's identity (R)";
}

test "two commanders combine their identities" {
    t1 = _lead("Thrasios, Triton Hero", ["G", "U"]);
    t2 = _lead("Tymna the Weaver", ["B", "W"]);
    bolt = _line("Lightning Bolt", "main", 1, "Instant", {"commander": "Legal"}, {}, "", ["R"]);
    vs = [v for v in check_commander([t1, t2, bolt, _basics(97)], CMD) if v.rule == "colour-identity"];
    assert len(vs) == 1;
    assert vs[0].message == "Lightning Bolt (R) is outside Thrasios, Triton Hero and Tymna the Weaver's identity (WUBG)";
    assert commander_names([t1, t2]) == "Thrasios, Triton Hero and Tymna the Weaver";
}

test "no commander means no identity check" {
    cs = _line("Counterspell", "main", 1, "Instant", {"commander": "Legal"}, {}, "", ["U"]);
    assert _rules(check_commander([cs, _basics(99)], CMD)) == ["commander-count"];
}

test "sideboard and maybeboard cards are not identity-checked" {
    cs = "Counterspell";
    side = _line(cs, "sideboard", 1, "Instant", {"commander": "Legal"}, {}, "", ["U"]);
    maybe = _line("Brainstorm", "maybeboard", 1, "Instant", {"commander": "Legal"}, {}, "", ["U"]);
    assert check_commander([_krenko(), _basics(99), side, maybe], CMD) == [];
}
