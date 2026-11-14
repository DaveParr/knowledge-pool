"""Tests for the card catalogue module (`cards.jac`), run against a SQLite
catalogue built from the small fixture and only through the module's interface.

`jac test` has no pytest-style autouse fixture, so this file builds its own
tiny catalogue from the same fixtures `tests/conftest.py` uses for the pytest
suite, and points `KP_CATALOG` at it. `with entry` runs on every import, so
this happens once per test run before any `test` block below.
"""

import copy;
import os;
import from pathlib { Path }
import from catalog.ingest { build, load_atomic, load_oracle_tags }
import catalog.store as store;
import from cards {
    Card, card_node, find_card, search_cards, resolve_names, RefreshCards
}

glob CATALOG: Path = Path("data/test_catalog.sqlite"),
     ATOMIC: dict[str, any] = load_atomic(Path("tests/fixtures/atomic_small.json")),
     TAGS: tuple[list[tuple[any, ...]], list[tuple[any, ...]]] = load_oracle_tags(Path("tests/fixtures/oracle_tags_small.jsonl")),
     BOLT: str = "4457ed35-7c10-48c8-9776-456485fdf070";

with entry {
    build(ATOMIC, CATALOG, tags=TAGS);
    os.environ["KP_CATALOG"] = str(CATALOG.resolve());
    store.reset();
}

test "card_node pulls oracle tags from the catalogue" {
    card = card_node(BOLT);
    assert isinstance(card, Card);
    assert sorted(card.oracle_tags) == ["burn", "removal"];
}

test "a card with no taggings gets an empty oracle_tags list" {
    card = card_node("a3fb7228-e76b-4e96-a40e-20b5fed75685");  # Mountain
    assert isinstance(card, Card);
    assert card.oracle_tags == [];
}

test "card_node copies stats, keywords and each face of a double-faced card" {
    card = card_node("edd531b9-f615-4399-8c8c-1c5e18c4acbf");  # Delver of Secrets
    assert isinstance(card, Card);
    assert (card.power, card.toughness, card.loyalty, card.defense) == ("1", "1", "", "");
    assert card.keywords == ["Flying", "Transform"];
    assert [f.name for f in card.faces] == ["Delver of Secrets", "Insectile Aberration"];
    back = card.faces[1];
    assert (back.mana_cost, back.type_line, back.text) == ("", "Creature — Human Insect", "Flying");
    assert (back.power, back.toughness) == ("3", "2");
}

test "a one-face card has no faces; its row holds the rules text" {
    card = card_node(BOLT);
    assert isinstance(card, Card);
    assert card.faces == [];
    assert card.power == "";
    assert card.keywords == [];
}

test "card_node returns None for an unknown oracle id" {
    assert card_node("no-such-oracle-id") is None;
}

test "find_card looks up by oracle id, exact name or either face" {
    assert find_card(BOLT)["name"] == "Lightning Bolt";
    assert find_card("lightning bolt")["oracle_id"] == BOLT;
    assert find_card("Ice")["name"] == "Fire // Ice";
    assert find_card("xyzzy") is None;
    assert find_card("") is None;
}

test "search_cards and resolve_names read the catalogue" {
    assert search_cards("lightning bolt").hits[0].oracle_id == BOLT;
    got = resolve_names(["Lightning Bolt", "Lightnig Bolt", "xyzzy"]);
    assert [e["oracle_id"] for e in got["exact"]] == [BOLT];
    assert got["fuzzy"][0]["candidates"][0]["name"] == "Lightning Bolt";
    assert got["unknown"] == ["xyzzy"];
}

test "re-ingest then one RefreshCards updates every field on existing Card nodes" {
    card = card_node(BOLT);
    assert isinstance(card, Card);
    changed: dict[str, any] = copy.deepcopy(ATOMIC);
    face: dict[str, any] = changed["data"]["Lightning Bolt"][0] as dict[str, any];
    face["manaCost"] = "{1}{R}";
    face["manaValue"] = 2.0;
    face["colorIdentity"] = ["R", "G"];
    face["types"] = ["Sorcery"];
    face["type"] = "Sorcery";
    face["text"] = "Lightning Bolt deals 4 damage to any target.";
    face["legalities"] = {"modern": "Banned"};
    face["producedMana"] = ["R"];
    face["power"] = "3";
    face["toughness"] = "1";
    face["loyalty"] = "4";
    face["defense"] = "2";
    face["keywords"] = ["Haste"];
    face["leadershipSkills"] = {"commander": True};
    face["isGameChanger"] = True;
    changed["data"]["Lightning Bolt"].append({"faceName": "Bolt Back", "type": "Instant", "text": "Draw a card."});
    changed["data"]["Lightning Bot"] = changed["data"].pop("Lightning Bolt");
    try {
        build(changed, CATALOG, tags=([], [("4457ed35-7c10-48c8-9776-456485fdf070", "burn")]));

        result = root spawn RefreshCards();

        assert result.reports[0] >= 1;
        assert card.name == "Lightning Bot";
        assert card.mana_cost == "{1}{R}";
        assert card.mana_value == 2.0;
        assert card.colour_identity == ["R", "G"];
        assert card.types == ["Sorcery"];
        assert card.type_line == "Sorcery // Instant";
        assert card.text == "Lightning Bolt deals 4 damage to any target.\n//\nDraw a card.";
        assert card.legal == {"modern": "Banned"};
        assert card.oracle_tags == ["burn"];
        assert card.produced_mana == ["R"];
        assert (card.power, card.toughness, card.loyalty, card.defense) == ("3", "1", "4", "2");
        assert card.keywords == ["Haste"];
        assert card.leadership == {"commander": True};
        assert card.game_changer;
        assert [f.name for f in card.faces] == ["Lightning Bolt", "Bolt Back"];
        assert card.faces[1].text == "Draw a card.";
        # Lookups see the new build too, not a connection to the old file.
        assert find_card(BOLT)["name"] == "Lightning Bot";
    } finally {
        build(ATOMIC, CATALOG, tags=TAGS);
        _ = root spawn RefreshCards();
    }
    assert card.name == "Lightning Bolt";
    assert sorted(card.oracle_tags) == ["burn", "removal"];
    assert card.faces == [];
}

test "RefreshCards leaves a card the new catalogue no longer has untouched" {
    card = card_node(BOLT);
    assert isinstance(card, Card);
    without: dict[str, any] = copy.deepcopy(ATOMIC);
    without["data"].pop("Lightning Bolt");
    try {
        build(without, CATALOG, tags=TAGS);
        _ = root spawn RefreshCards();
        assert card.name == "Lightning Bolt";
        assert find_card(BOLT) is None;
    } finally {
        build(ATOMIC, CATALOG, tags=TAGS);
        _ = root spawn RefreshCards();
    }
}
