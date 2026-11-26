"""Seam A for the cost of reading a deck or the quest list against a large
collection: `perform` called in process as a user, timed.

A read looks each deck card up in the collection. Once the lookups rebuilt the
collection every time, so a read cost deck lines x collection size, and all the
while the runner's one lock held every other call back (#241).
"""

import os;
import time;
import from pathlib { Path }
import from catalog.ingest { build, load_atomic, load_oracle_tags }
import catalog.store as store;
import from graph_runner { run_walker, STARTED_FOR_GUEST }
import from deck_operations { perform }
import from decks { Deck, DeckView, CreateDeck, EditDeck, GetDeck }
import from collection { ImportCollection, ChangeCollection, GetCollection }
import from quest_list { GetQuestList }
import from collection_views { QuestListView, CollectionView }

glob CATALOG: Path = Path("data/test_collection_scale_catalog.sqlite"),
     CALLER: str = "user_test_scale_alice",
     DECK_LINES: int = 60,
     LIMIT_S: float = 3.0,
     COLLECTION_LIMIT_S: float = 0.5;

with entry {
    build(
        load_atomic(Path("tests/fixtures/atomic_small.json")),
        CATALOG,
        tags=load_oracle_tags(Path("tests/fixtures/oracle_tags_small.jsonl"))
    );
    os.environ["KP_CATALOG"] = str(CATALOG.resolve());
    store.reset();
}

"""Every oracle id of the test catalogue."""
def _oracle_ids -> list[str] {
    return [str(r["oracle_id"]) for r in store.connection().execute("select oracle_id from cards")];
}

"""`CALLER` with a deck of `DECK_LINES` cards, none short in the collection,
and every card of the catalogue in the collection: the deck's id."""
def _caller_with_big_collection -> str {
    oids = _oracle_ids();
    deck = run_walker(CALLER, CreateDeck(name="Scale")).reports[0] as Deck;
    did = jid(deck);
    perform(CALLER, EditDeck(
        deck_id=did,
        changes=[{"oracle_id": o, "count": 1, "zone": "main", "reason": "test"} for o in oids[:DECK_LINES]]
    ));
    names = [str(r["name"]) for r in store.connection().execute("select name from cards")];
    perform(CALLER, ImportCollection(format="text", text="\n".join([f"1 {n}" for n in names])));
    return did;
}

test "reading a deck against a collection of the whole catalogue is fast" {
    did = _caller_with_big_collection();
    from_start = time.monotonic();
    view = perform(CALLER, GetDeck(deck_id=did)).reports[0] as DeckView;
    assert time.monotonic() - from_start < LIMIT_S;
    assert view.sleeveable;
}

test "reading the quest list against a collection of the whole catalogue is fast" {
    _caller_with_big_collection();
    from_start = time.monotonic();
    view = perform(CALLER, GetQuestList()).reports[0] as QuestListView;
    assert time.monotonic() - from_start < LIMIT_S;
    assert len(view.lines) == 0;
}

test "reading a collection of the whole catalogue is fast" {
    _caller_with_big_collection();
    perform(CALLER, ChangeCollection(oracle_id=_oracle_ids()[7], count=4, reason="test"));
    from_start = time.monotonic();
    view = perform(CALLER, GetCollection()).reports[0] as CollectionView;
    assert time.monotonic() - from_start < COLLECTION_LIMIT_S;
    assert len(view.cards) == len(_oracle_ids());
    assert sorted([l.count for l in view.cards]) == [1] * (len(view.cards) - 1) + [5];
    assert [l.count for l in view.cards if l.oracle_id == _oracle_ids()[7]] == [5];
}
