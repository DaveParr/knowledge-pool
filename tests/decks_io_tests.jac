"""Walker-free tests for the mtgdeck/1 zone and entry metadata additions."""

import from decks { Holds, DECK_ZONES }

test "Holds defaults carry no role, tags, lock or reason" {
    h = Holds();
    assert h.role == "";
    assert h.tags == [];
    assert h.locked == False;
    assert h.reason == "";
}

test "DECK_ZONES covers all five mtgdeck/1 zones" {
    assert DECK_ZONES == ["commander", "companion", "main", "sideboard", "maybeboard"];
}
