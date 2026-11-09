"""Tests for the Commander format checks. None of these need a graph."""

import from card_lines { CardLine }
import from legality { Format, Violation, check_commander }
import from commander { can_lead, commanders }

glob CMD: Format = Format(name="commander", label="Commander", min_main=100, copy_limit=1, sideboard_max=0);

"""A card line with only the fields a test cares about."""
def _line(
    name: str,
    zone: str,
    count: int,
    type_line: str = "Instant",
    legal: dict[str, str] = {"commander": "Legal"},
    leadership: dict[str, bool] = {},
    text: str = ""
) -> CardLine {
    return CardLine(
        oracle_id=name,
        name=name,
        zone=zone,
        count=count,
        type_line=type_line,
        legal=legal,
        leadership=leadership,
        text=text
    );
}

def _krenko() -> CardLine {
    return _line("Krenko, Mob Boss", "commander", 1, "Legendary Creature — Goblin", {"commander": "Legal"}, {"commander": True});
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
