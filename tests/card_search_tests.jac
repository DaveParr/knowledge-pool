"""Tests for the deck-aware card search behind the card search MCP app
(`card_search` in mcp_tools.jac): in-deck counts, the Markdown fallback,
and a catalogue failure coming back as `error`."""

import os;
import from pathlib { Path }
import from catalog.ingest { build, load_atomic, load_oracle_tags }
import catalog.store as store;
import from mcp_tools { search_with_holdings }
import from mcp_builders { search_markdown }

glob CATALOG: Path = Path("data/test_catalog_search.sqlite"),
     BOLT: str = "4457ed35-7c10-48c8-9776-456485fdf070";

with entry {
    build(
        load_atomic(Path("tests/fixtures/atomic_small.json")),
        CATALOG,
        tags=load_oracle_tags(Path("tests/fixtures/oracle_tags_small.jsonl"))
    );
    os.environ["KP_CATALOG"] = str(CATALOG.resolve());
    store.reset();
}

"""A deck view with 3 Lightning Bolt in main and 1 in the sideboard."""
def bolt_deck -> dict[str, any] {
    return {
        "id": "d1",
        "name": "Burn",
        "format": "modern",
        "main_total": 3,
        "sideboard_total": 1,
        "cards": [
            {"oracle_id": BOLT, "zone": "main", "count": 3},
            {"oracle_id": BOLT, "zone": "sideboard", "count": 1}
        ]
    };
}

test "hits carry the copies the deck holds per zone" {
    got = search_with_holdings(bolt_deck(), "lightning", 10);
    assert got["error"] == "";
    assert got["deck"]["name"] == "Burn";
    by_name = {h["name"]: h for h in got["hits"]};
    assert by_name["Lightning Bolt"]["in_deck"] == {"main": 3, "sideboard": 1};
    assert by_name["Ball Lightning"]["in_deck"] == {};
}

test "the Markdown fallback has an In deck column and asks what to add" {
    text = search_markdown(search_with_holdings(bolt_deck(), "lightning bolt", 10));
    assert "| Card | Cost | Type | In deck | Oracle id |" in text;
    assert f"| Lightning Bolt | {{R}} | Instant | 3 main, 1 sideboard | `{BOLT}` |" in text;
    assert text.endswith("Which should I add, how many, and to main or sideboard?");
}

test "no matches says so" {
    assert search_markdown(search_with_holdings(bolt_deck(), "zzqxv", 10)).startswith("No cards match \"zzqxv\".");
}

test "a missing catalogue comes back as error, not an exception" {
    os.environ["KP_CATALOG"] = str(Path("data/no_such_catalog.sqlite").resolve());
    store.reset();
    try {
        got = search_with_holdings(bolt_deck(), "lightning", 10);
        assert got["error"].startswith("Card search failed");
        assert got["hits"] == [];
    } finally {
        os.environ["KP_CATALOG"] = str(CATALOG.resolve());
        store.reset();
    }
}

test "the deck says whether it is the caller's own, so the view can hide Add on another user's" {
    assert search_with_holdings(bolt_deck(), "lightning", 10)["deck"]["mine"];
    assert not search_with_holdings(bolt_deck(), "lightning", 10, False)["deck"]["mine"];
}
