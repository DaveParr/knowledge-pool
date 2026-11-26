"""The MCP tools' text builders (`mcp_builders.jac`) as pure functions: data in,
text out, with no graph, catalogue or server."""

import from json_object { JsonObject }
import from mcp_builders {
    deck_brief, deck_markdown, game_changers_note, power_toughness, mana_brief, mana_markdown,
    search_brief, search_markdown, md_cell, export_brief, export_text, LOSSY_DROPS
}

def card(name: str, zone: str, count: int, power: str = "", toughness: str = "") -> JsonObject {
    return {
        "name": name, "zone": zone, "count": count, "mana_cost": "{R}", "type_line": "Creature",
        "power": power, "toughness": toughness
    };
}

def deck_view(legal: bool = True, game_changers: JsonObject | None = None) -> JsonObject {
    return {
        "name": "Burn", "format": "modern", "main_total": 4, "sideboard_total": 1, "legal": legal,
        "violations": [] if legal else [{"message": "Too few cards"}],
        "game_changers": game_changers,
        "cards": [card("Goblin Guide", "main", 4, "2", "2"), card("Shock", "sideboard", 1)]
    };
}

def analysis(lands: int = 52) -> JsonObject {
    return {
        "name": "Burn", "format": "modern",
        "mana": {"land_count": lands, "pips": {"R": 8}, "sources": {"R": lands}},
        "curve": {"buckets": {"0": 0, "1": 8, "2": 0}, "average_mv": 1.0}
    };
}

def search_result(hits: list[JsonObject]) -> JsonObject {
    return {"deck": {"name": "Burn"}, "query": "bolt", "limit": 20, "hits": hits, "error": None};
}

def bolt_hit(in_deck: dict[str, int]) -> JsonObject {
    return {"oracle_id": "abc", "name": "Lightning Bolt", "mana_cost": "{R}", "type_line": "Instant", "in_deck": in_deck};
}

test "power and toughness is front-face P/T, or empty when the card has none" {
    assert power_toughness({"power": "2", "toughness": "3"}) == "2/3";
    assert power_toughness({"power": "", "toughness": ""}) == "";
}

test "a Markdown cell loses its pipes and line breaks" {
    assert md_cell("a|b\nc") == "a\\|b c";
}

test "the deck table has a heading, totals and one table per zone that holds cards" {
    md = deck_markdown(deck_view());
    assert md.startswith("## Burn\nmodern, 4 main, 1 sideboard. Legal.");
    assert "### Main deck\n" in md and "### Sideboard\n" in md;
    assert "### Commander" not in md;
    assert "| 4 | Goblin Guide | {R} | Creature | 2/2 |" in md;
    assert "| 1 | Shock | {R} | Creature |  |" in md;
}

test "an illegal deck lists its violations in the table and the brief" {
    assert "Not legal: Too few cards" in deck_markdown(deck_view(False));
    assert "Not legal: Too few cards. " in deck_brief(deck_view(False));
}

test "the deck brief says what the user sees and not to list the cards" {
    brief = deck_brief(deck_view());
    assert brief.startswith("Shown to the user as an expandable deck list: Burn, modern, 4 main, 1 sideboard. Legal. ");
    assert "do not list the cards again" in brief;
}

test "Game Changers appear for a Commander deck and are absent otherwise" {
    gc = {"count": 1, "cards": ["Rhystic Study"], "bracket_hint": "Bracket 3"};
    assert game_changers_note(deck_view()) == "";
    note = game_changers_note(deck_view(True, gc));
    assert note == "Game Changers: 1 (Rhystic Study). Bracket hint from Game Changers only: Bracket 3. ";
    assert note.strip() in deck_markdown(deck_view(True, gc));
    assert note in deck_brief(deck_view(True, gc));
}

test "the mana brief puts the numbers on one line and the Markdown has tables" {
    brief = mana_brief(analysis());
    assert "52 lands, 8 non-land cards, average mana value 1.00" in brief;
    assert "Red 8 pips, 52 sources" in brief;
    assert "|" not in brief;
    md = mana_markdown(analysis());
    assert "| Cards | 0 | 8 | 0 |" in md and "| Red | 8 | 52 |" in md;
}

test "a deck with no coloured mana says so" {
    a = analysis(0);
    a["mana"] = {"land_count": 0, "pips": {}, "sources": {}};
    assert "no coloured mana yet" in mana_brief(a);
    assert "No coloured mana in the main deck yet." in mana_markdown(a);
}

test "search Markdown is a table with an In deck column and ends with a question" {
    md = search_markdown(search_result([bolt_hit({"main": 4})]));
    assert md.startswith("1 card matches \"bolt\" (deck: Burn):");
    assert "| Lightning Bolt | {R} | Instant | 4 main | `abc` |" in md;
    assert md.endswith("Which should I add, how many, and to main or sideboard?");
}

test "a card the deck does not hold shows a dash, and no hits says so" {
    assert "| - |" in search_markdown(search_result([bolt_hit({})]));
    assert search_markdown(search_result([])).startswith("No cards match \"bolt\".");
    assert search_brief(search_result([])) == search_markdown(search_result([]));
}

test "the search brief lists oracle ids and what the deck holds, not a table" {
    brief = search_brief(search_result([bolt_hit({"main": 4})]));
    assert brief.startswith("Shown to the user as a search panel: 1 card matches \"bolt\"");
    assert "Lightning Bolt (abc; 4 main in deck)" in brief;
    assert "|" not in brief;
}

test "a lossy export's text gives the list in a code block and says what it drops" {
    got = export_text({"format": "arena", "name": "Burn", "content": "Deck\n4 Lightning Bolt"});
    assert got.startswith("Exported Burn as MTGA/MTGO. It " + LOSSY_DROPS);
    assert got.endswith("```\nDeck\n4 Lightning Bolt\n```");
}

test "a lossless export's text leads with a summary and carries the whole JSON" {
    got = export_text({"format": "mtgdeck1", "name": "Burn", "content": "{\"a\": 1}"});
    assert got.startswith("Exported Burn as mtgdeck/1 (lossless, 1 lines, 8 characters).");
    assert got.endswith("```json\n{\"a\": 1}\n```");
}

test "the export brief tells the model not to paste the export" {
    assert export_brief().startswith("Shown to the user in the export view");
    assert "do not paste it into the chat" in export_brief();
}

test "the deck table and brief say how many copies are owned, what is missing and whether the deck is sleeveable" {
    view = {
        **deck_view(),
        "missing": [{"oracle_id": "g", "name": "Goblin Guide", "count": 3}],
        "sleeveable": False,
        "cards": [{**card("Goblin Guide", "main", 4, "2", "2"), "collection_count": 1}]
    };
    md = deck_markdown(view);
    assert "| 4 (1 owned) | Goblin Guide |" in md;
    assert "Not sleeveable: missing 3 Goblin Guide." in md;
    assert "Not sleeveable: missing 3 Goblin Guide. " in deck_brief(view);
    sleeved = {**view, "missing": [], "sleeveable": True};
    assert "Sleeveable." in deck_markdown(sleeved);
}
