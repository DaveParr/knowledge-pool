"""Seam A for the cost of reading a deck or the quest list against a large
collection: `perform` called in process as a user, timed.

A read looks each deck card up in the collection. Once the lookups rebuilt the
collection every time, so a read cost deck lines x collection size, and all the
while the runner's one lock held every other call back (#241).
"""

import copy;
import os;
import uuid;
import time;
import from pathlib { Path }
import from catalog.ingest { build, load_atomic, load_oracle_tags }
import catalog.store as store;
import from graph_runner { run_walker, STARTED_FOR_GUEST }
import from deck_operations { perform }
import from decks { Deck, DeckView, CreateDeck, EditDeck, GetDeck }
import from collection { ImportCollection, ChangeCollection, GetCollection }
import from quest_list { GetQuestList }
import from collection_views { QuestListView, CollectionView, ImportCollectionResult }

glob CATALOG: Path = Path("data/test_collection_scale_catalog.sqlite"),
     CALLER: str = "user_test_scale_alice",
     SCALE_CARDS: int = 520,
     DECK_LINES: int = 60,
     LIMIT_S: float = 3.0,
     IMPORT_LIMIT_S: float = 8.0,
     COLLECTION_LIMIT_S: float = 1.5,
     CHANGED_CARD: int = 7,
     CHANGED_COPIES: int = 5;

"""The fixture catalogue grown to `SCALE_CARDS` cards: the hand-trimmed fixture's
single-face cards cloned under new names and oracle ids, so the collection under
test is bigger than the ticket's 500 cards without a second fixture file to keep."""
def _scale_catalogue -> dict[str, any] {  # jac:ignore[W1037]
    atomic = load_atomic(Path("tests/fixtures/atomic_small.json"));
    singles = [(name, faces[0]) for (name, faces) in atomic["data"].items() if len(faces) == 1];
    n = 0;
    while len(atomic["data"]) < SCALE_CARDS {
        (name, face) = singles[n % len(singles)];
        n += 1;
        clone = copy.deepcopy(face);
        clone["name"] = f"{name} Clone {n}";
        clone["identifiers"] = {"scryfallOracleId": str(uuid.uuid5(uuid.NAMESPACE_DNS, clone["name"]))};
        atomic["data"][clone["name"]] = [clone];
    }
    return atomic;
}

with entry {
    build(
        _scale_catalogue(),
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

"""Every card name of the test catalogue."""
def _names -> list[str] {
    return [str(r["name"]) for r in store.connection().execute("select name from cards")];
}

"""A pasted list of one copy of every card of the test catalogue."""
def _whole_catalogue_list -> str {
    return "\n".join([f"1 {n}" for n in _names()]);
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
    perform(CALLER, ImportCollection(format="text", text=_whole_catalogue_list()));
    return did;
}

test "a deck is read within the limit against a collection of the whole catalogue, and is sleeveable" {
    did = _caller_with_big_collection();
    from_start = time.monotonic();
    view = perform(CALLER, GetDeck(deck_id=did)).reports[0] as DeckView;
    assert time.monotonic() - from_start < LIMIT_S;
    assert view.sleeveable;
}

test "the quest list is read within the limit against a collection of the whole catalogue, and is empty" {
    _caller_with_big_collection();
    from_start = time.monotonic();
    view = perform(CALLER, GetQuestList()).reports[0] as QuestListView;
    assert time.monotonic() - from_start < LIMIT_S;
    assert len(view.lines) == 0;
}

test "a collection of the whole catalogue is read within the limit, each card with its own count" {
    _caller_with_big_collection();
    perform(CALLER, ChangeCollection(oracle_id=_oracle_ids()[CHANGED_CARD], count=CHANGED_COPIES - 1, reason="test"));
    from_start = time.monotonic();
    view = perform(CALLER, GetCollection()).reports[0] as CollectionView;
    assert time.monotonic() - from_start < COLLECTION_LIMIT_S;
    assert len(view.cards) == len(_oracle_ids());
    assert sorted([l.count for l in view.cards]) == [1] * (len(view.cards) - 1) + [CHANGED_COPIES];
    assert [l.count for l in view.cards if l.oracle_id == _oracle_ids()[CHANGED_CARD]] == [CHANGED_COPIES];
}

test "a list of the whole catalogue is imported within the limit, every card resolved" {
    from_start = time.monotonic();
    result = perform(CALLER, ImportCollection(format="text", text=_whole_catalogue_list())).reports[0] as ImportCollectionResult;
    assert time.monotonic() - from_start < IMPORT_LIMIT_S;
    assert result.unresolved == [];
    assert len(result.collection.cards) == len(_oracle_ids());
}
