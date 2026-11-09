"""Tests for the Commander format checks. None of these need a graph."""

import from card_lines { CardLine }
import from legality { Format, Violation, check_commander }
import from commander { can_lead, commanders, identity, identity_label, commander_names, partner_ability, partner_abilities, is_background, is_time_lord_doctor, pair_problem, bracket_hint, game_changers }

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
    colour_identity: list[str] = [],
    game_changer: bool = False
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
        colour_identity=colour_identity,
        game_changer=game_changer
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

test "three commanders is commander-count" {
    vs = check_commander([_thrasios(), _tymna(), _krenko(), _basics(97)], CMD);
    msgs = [v.message for v in vs if v.rule == "commander-count"];
    assert msgs == ["The commander zone holds 3 cards; Commander allows one, or two that pair."];
    assert "commander-pair" not in _rules(vs);
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

def _cmdr(name: str, type_line: str, text: str, colours: list[str] = []) -> CardLine {
    return _line(name, "commander", 1, type_line, {"commander": "Legal"}, {"commander": True}, text, colours);
}

def _thrasios() -> CardLine {
    return _cmdr("Thrasios, Triton Hero", "Legendary Creature — Merfolk Wizard", "{4}: Scry 1, then reveal the top card of your library. If it's a land card, put it onto the battlefield tapped. Otherwise, draw a card.\nPartner (You can have two commanders if both have partner.)", ["G", "U"]);
}

def _tymna() -> CardLine {
    return _cmdr("Tymna the Weaver", "Legendary Creature — Human Cleric", "Lifelink\nAt the beginning of each of your postcombat main phases, you may pay X life, where X is the number of opponents that were dealt combat damage this turn. If you do, draw X cards.\nPartner (You can have two commanders if both have partner.)", ["B", "W"]);
}

def _pir() -> CardLine {
    return _cmdr("Pir, Imaginative Rascal", "Legendary Creature — Human", "Partner with Toothy, Imaginary Friend (When this creature enters, target player may put Toothy into their hand from their library, then shuffle.)\nIf one or more counters would be put on a permanent your team controls, that many plus one of each of those kinds of counters are put on that permanent instead.", ["G"]);
}

def _toothy() -> CardLine {
    return _cmdr("Toothy, Imaginary Friend", "Legendary Creature — Illusion", "Partner with Pir, Imaginative Rascal (When this creature enters, target player may put Pir into their hand from their library, then shuffle.)\nWhenever you draw a card, put a +1/+1 counter on Toothy.\nWhen Toothy leaves the battlefield, draw a card for each +1/+1 counter on it.", ["U"]);
}

def _bjorna() -> CardLine {
    return _cmdr("Bjorna, Nightfall Alchemist", "Legendary Creature — Human", "{T}, Sacrifice an artifact: Bjorna, Nightfall Alchemist deals 1 damage to target creature. Goad that creature. (Until your next turn, that creature attacks each combat if able and attacks a player other than you if able.)\nPartner—Friends forever (You can have two commanders if both have this ability.)", ["R", "U"]);
}

def _sophina() -> CardLine {
    return _cmdr("Sophina, Spearsage Deserter", "Legendary Creature — Human Soldier", "Menace\nWhenever Sophina, Spearsage Deserter attacks, investigate once for each nontoken attacking creature. (To investigate, create a Clue token. It's an artifact with \"{2}, Sacrifice this artifact: Draw a card.\")\nPartner—Friends forever (You can have two commanders if both have this ability.)", ["R", "W"]);
}

def _abby() -> CardLine {
    return _cmdr("Abby, Merciless Soldier", "Legendary Creature — Human Survivor", "When you cast this spell, create a number of 1/1 black Fungus Zombie creature tokens named Cordyceps Infected equal to the amount of mana spent to cast it.\nAbby enters under the control of an opponent of your choice.\nPartner—Survivors (You can have two commanders if both have this ability.)", ["G", "R"]);
}

def _wilson() -> CardLine {
    return _cmdr("Wilson, Refined Grizzly", "Legendary Creature — Bear Warrior", "This spell can't be countered.\nReach, vigilance, trample\nWard {2} (Whenever this creature becomes the target of a spell or ability an opponent controls, counter it unless that player pays {2}.)\nChoose a Background (You can have a Background as a second commander.)", ["G"]);
}

def _sage() -> CardLine {
    return _line("Candlekeep Sage", "commander", 1, "Legendary Enchantment — Background", {"commander": "Legal"}, {}, "Commander creatures you own have \"When this creature enters or leaves the battlefield, draw a card.\"", ["U"]);
}

def _tenth() -> CardLine {
    return _cmdr("The Tenth Doctor", "Legendary Creature — Time Lord Doctor", "Allons-y! — Whenever you attack, exile cards from the top of your library until you exile a nonland card. Put three time counters on it. If it doesn't have suspend, it gains suspend.\nTimey-Wimey — {7}: Time travel three times. Activate only as a sorcery. (For each suspended card you own and each permanent you control with a time counter on it, you may add or remove a time counter. Then do it two more times.)", ["R", "U"]);
}

def _rose() -> CardLine {
    return _cmdr("Rose Tyler", "Legendary Creature — Human", "Rose Tyler gets +1/+1 for each time counter on it.\nBad Wolf — Whenever Rose Tyler attacks, put a time counter on it for each suspended card you own and each other permanent you control with a time counter on it.\nDoctor's companion (You can have two commanders if the other is the Doctor.)", ["W"]);
}

test "partner ability reads the keyword line, not other text" {
    assert partner_ability(_thrasios()) == "partner";
    assert partner_ability(_pir()) == "partner with:Toothy, Imaginary Friend";
    assert partner_ability(_bjorna()) == "partner—Friends forever";
    assert partner_ability(_wilson()) == "choose a background";
    assert partner_ability(_rose()) == "doctor's companion";
    assert partner_ability(_krenko()) == "";
    other = _cmdr("Other", "Legendary Creature — Human", "Creatures you control with partner get +1/+1.");
    assert partner_ability(other) == "";
}

test "backgrounds and Time Lord Doctors are told from their type lines" {
    assert is_background(_sage());
    assert not is_background(_krenko());
    assert is_time_lord_doctor(_tenth());
    assert not is_time_lord_doctor(_rose());
}

test "each pair kind is legal" {
    assert pair_problem(_thrasios(), _tymna()) == "";
    assert pair_problem(_pir(), _toothy()) == "";
    assert pair_problem(_bjorna(), _sophina()) == "";
    assert pair_problem(_wilson(), _sage()) == "";
    assert pair_problem(_tenth(), _rose()) == "";
}

test "illegal pairs name the reason" {
    assert pair_problem(_krenko(), _thrasios()) == "Krenko, Mob Boss has no partner ability";
    assert pair_problem(_pir(), _thrasios()) == "Pir, Imaginative Rascal can only partner with Toothy, Imaginary Friend";
    assert pair_problem(_bjorna(), _abby()) == "Partner—Friends forever and Partner—Survivors don't pair";
    assert pair_problem(_wilson(), _thrasios()) == "Wilson, Refined Grizzly needs a Background";
    assert pair_problem(_rose(), _krenko()) == "Rose Tyler needs a Time Lord Doctor";
}

test "a Background can lead only beside a choose-a-Background commander" {
    alone = check_commander([_sage(), _basics(99)], CMD);
    assert "commander-eligible" in _rules(alone);
    paired = check_commander([_sage(), _wilson(), _basics(98)], CMD);
    assert "commander-eligible" not in _rules(paired);
}

test "same card twice is not a pair" {
    t = _thrasios();
    t.count = 2;
    vs = check_commander([t, _basics(98)], CMD);
    assert "commander-pair" not in _rules(vs);
    assert "copy-limit" in _rules(vs);
}

test "legal pairs have no pair violation" {
    vs = check_commander([_thrasios(), _tymna(), _basics(98)], CMD);
    assert "commander-pair" not in _rules(vs);
}

test "the commander-pair message names both cards" {
    vs = check_commander([_krenko(), _thrasios(), _basics(98)], CMD);
    msgs = [v.message for v in vs if v.rule == "commander-pair"];
    assert msgs == ["Krenko, Mob Boss and Thrasios, Triton Hero can't be commanders together: Krenko, Mob Boss has no partner ability."];
}

def _amy() -> CardLine {
    return _cmdr("Amy Pond", "Legendary Creature — Human", "Partner with Rory Williams (When this creature enters, target player may put Rory into their hand from their library, then shuffle.)\nWhenever Amy Pond deals combat damage to a player, choose a suspended card you own and remove that many time counters from it.\nDoctor's companion (You can have two commanders if the other is the Doctor.)", ["R"]);
}

def _rory() -> CardLine {
    return _cmdr("Rory Williams", "Legendary Creature — Human Soldier", "Partner with Amy Pond\nFirst strike, lifelink\nThe Last Centurion — When you cast this spell from anywhere other than exile, exile it with three time counters on it. It gains suspend. Then investigate. (Create a Clue token. It's an artifact with \"{2}, Sacrifice this token: Draw a card.\")", ["U", "W"]);
}

test "a card with two pairing abilities lists both and pairs by either" {
    assert partner_abilities(_amy()) == ["partner with:Rory Williams", "doctor's companion"];
    assert partner_ability(_amy()) == "partner with:Rory Williams";
    assert pair_problem(_amy(), _tenth()) == "";
    assert pair_problem(_tenth(), _amy()) == "";
    assert pair_problem(_amy(), _rory()) == "";
    assert pair_problem(_amy(), _krenko()) == "Amy Pond needs a Time Lord Doctor";
}

def _syn(name: str, text: str) -> CardLine {
    return _cmdr(name, "Legendary Creature — Human", text);
}

test "a partner-with aimed at the other card is not blamed for a mismatch" {
    a = _syn("A", "Partner with B");
    assert pair_problem(a, _syn("B", "Partner")) == "Partner with B and Partner don't pair";
    assert pair_problem(a, _syn("B", "Partner with C")) == "B can only partner with C";
}

test "bracket hint bands" {
    assert bracket_hint(0) == "Bracket 1–2";
    assert bracket_hint(1) == "Bracket 3";
    assert bracket_hint(3) == "Bracket 3";
    assert bracket_hint(4) == "Bracket 4+";
    assert bracket_hint(9) == "Bracket 4+";
}

test "game changers are listed by name from commander, companion and main" {
    lines = [
        _line("Rhystic Study", "main", 1, game_changer=True),
        _line("Chrome Mox", "main", 1, game_changer=True),
        _line("Chrome Mox", "commander", 1, game_changer=True),
        _line("Mana Vault", "sideboard", 1, game_changer=True),
        _line("Counterspell", "main", 1)
    ];
    gc = game_changers(lines);
    assert gc.cards == ["Chrome Mox", "Rhystic Study"];
    assert gc.count == 2;
    assert gc.bracket_hint == "Bracket 3";
}
