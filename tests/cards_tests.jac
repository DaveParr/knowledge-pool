"""Walker and function tests for the catalogue's graph Card node.

`jac test` has no pytest-style autouse fixture, so this file builds its own
tiny catalogue from the same fixtures `tests/conftest.py` uses for the pytest
suite, and points `KP_CATALOG` at it. `with entry` runs on every import, so
this happens once per test run before any `test` block below.
"""

import os;
import from pathlib { Path }
import from catalog.ingest { build, load_atomic, load_oracle_tags }
import catalog.store as store;
import from cards { Card, card_node, SyncCardTags }

with entry {
    out = Path("data/test_catalog.sqlite");
    build(
        load_atomic(Path("tests/fixtures/atomic_small.json")),
        out,
        tags=load_oracle_tags(Path("tests/fixtures/oracle_tags_small.jsonl"))
    );
    os.environ["KP_CATALOG"] = str(out.resolve());
    store.reset();
}

test "card_node pulls oracle tags from the catalogue" {
    card = card_node(root, "4457ed35-7c10-48c8-9776-456485fdf070");
    assert isinstance(card, Card);
    assert sorted(card.oracle_tags) == ["burn", "removal"];
}

test "a card with no taggings gets an empty oracle_tags list" {
    card = card_node(root, "a3fb7228-e76b-4e96-a40e-20b5fed75685");  # Mountain
    assert isinstance(card, Card);
    assert card.oracle_tags == [];
}

test "SyncCardTags refreshes an already-materialized card's tags" {
    card = card_node(root, "4457ed35-7c10-48c8-9776-456485fdf070");
    assert isinstance(card, Card);
    card.oracle_tags = [];  # simulate a Card node from before the catalogue had tags

    result = root spawn SyncCardTags();

    assert result.reports[0] >= 1;
    assert sorted(card.oracle_tags) == ["burn", "removal"];
}
