"""Seam A for the collection: `perform` called in process as users.

Every behaviour is checked through the one call both edges make, as two
users, and by what a user sees: their collection card by card, and its
history. The catalogue is built from the small fixture.
"""

import os;
import from pathlib { Path }
import from catalog.ingest { build, load_atomic, load_oracle_tags }
import catalog.store as store;
import from walker_errors { WalkerError }
import from jaclang { JacRuntime as Jac }
import from graph_runner { STARTED_FOR_GUEST, call_function }
import from collection { Collection }
import from deck_operations { perform, page_walkers, OPERATIONS, OWN }
import from decks { CreateDeck, EditDeck, GetDeck, DeckView }
import from collection { REASON_IMPORTED, ChangeCollection, GetCollection, ImportCollection, ImportCollectionResult, CollectionView, MODE_ADD, MODE_REMOVE, MODE_SET }

glob CATALOG: Path = Path("data/test_collection_catalog.sqlite"),
     ALICE: str = "user_test_collection_alice",
     BOB: str = "user_test_collection_bob";

with entry {
    build(
        load_atomic(Path("tests/fixtures/atomic_small.json")),
        CATALOG,
        tags=load_oracle_tags(Path("tests/fixtures/oracle_tags_small.jsonl"))
    );
    os.environ["KP_CATALOG"] = str(CATALOG.resolve());
    store.reset();
}

"""The oracle id of the card `name`."""
def _oid(name: str) -> str {
    return store.find_by_name(name)["oracle_id"] as str;
}

"""`caller` changes their collection; the walker error it gets, or None."""
def _change(caller: str, name: str, count: int, mode: str = "add", reason: str = "test") -> WalkerError | None {
    done = perform(caller, ChangeCollection(oracle_id=_oid(name), count=count, mode=mode, reason=reason));
    first = done.reports[0];
    return first if isinstance(first, WalkerError) else None;
}

"""`caller`'s collection as the view they read."""
def _collection(caller: str) -> CollectionView {
    return perform(caller, GetCollection()).reports[0] as CollectionView;
}

"""The count of the card `name` in `caller`'s collection."""
def _count(caller: str, name: str) -> int {
    return sum([l.count for l in _collection(caller).cards if l.oracle_id == _oid(name)]);
}

test "adding copies of a card puts them in the collection and logs why" {
    assert _change(ALICE, "Lightning Bolt", 3, reason="bought at FNM") is None;
    assert _count(ALICE, "Lightning Bolt") == 3;
    note = _collection(ALICE).history[-1];
    assert (note.name, note.before, note.after, note.reason, note.zone) == ("Lightning Bolt", 0, 3, "bought at FNM", "");
}

test "setting a card's count makes it exactly that, and a count of 0 takes the card out" {
    _change(ALICE, "Shock", 4);
    assert _change(ALICE, "Shock", 2, MODE_SET) is None;
    assert _count(ALICE, "Shock") == 2;
    assert _change(ALICE, "Shock", 0, MODE_SET) is None;
    assert _oid("Shock") not in [l.oracle_id for l in _collection(ALICE).cards];
    assert _collection(ALICE).history[-1].after == 0;
}

test "removing some copies leaves the rest" {
    _change(ALICE, "Counterspell", 3);
    assert _change(ALICE, "Counterspell", 1, MODE_REMOVE, "traded away") is None;
    assert _count(ALICE, "Counterspell") == 2;
    assert (_collection(ALICE).history[-1].before, _collection(ALICE).history[-1].after) == (3, 2);
}

test "removing more copies than the collection has is refused with refused-change, saying how many, and changes nothing" {
    _change(ALICE, "Llanowar Elves", 2);
    noted = len(_collection(ALICE).history);
    refused = _change(ALICE, "Llanowar Elves", 5, MODE_REMOVE);
    assert refused is not None;
    assert refused.code == "refused-change";
    assert "2" in refused.message;
    assert _count(ALICE, "Llanowar Elves") == 2;
    assert len(_collection(ALICE).history) == noted;
}

test "a change with no reason is refused and changes nothing" {
    refused = _change(BOB, "Shock", 1, reason="  ");
    assert refused is not None and refused.code == "refused-change";
    assert _count(BOB, "Shock") == 0;
}

test "a card that is not in the catalogue is refused" {
    done = perform(BOB, ChangeCollection(oracle_id="no-such-oracle-id", count=1, reason="test"));
    first = done.reports[0];
    assert isinstance(first, WalkerError) and first.code == "refused-change";
}

test "each user keeps their own collection" {
    _change(ALICE, "Sol Ring", 1);
    assert _count(ALICE, "Sol Ring") == 1;
    assert _count(BOB, "Sol Ring") == 0;
}

test "editing a deck leaves the collection as it was, and removing a card a deck uses is allowed" {
    _change(ALICE, "Rampant Growth", 2);
    before = _count(ALICE, "Rampant Growth");
    made = perform(ALICE, CreateDeck(name="Collection deck")).reports[0];
    deck_id = jid(made);
    edit = EditDeck(deck_id=deck_id, changes=[{"oracle_id": _oid("Rampant Growth"), "count": 3, "zone": "main", "reason": "test"}]);
    perform(ALICE, edit);
    assert _count(ALICE, "Rampant Growth") == before;
    assert _change(ALICE, "Rampant Growth", 2, MODE_REMOVE) is None;
    deck = perform(ALICE, GetDeck(deck_id=deck_id)).reports[0] as DeckView;
    assert [l.count for l in deck.cards if l.oracle_id == _oid("Rampant Growth")] == [3];
}

test "a negative count is refused and changes nothing" {
    refused = _change(BOB, "Shock", -2, MODE_SET);
    assert refused is not None and refused.code == "refused-change";
    assert _count(BOB, "Shock") == 0;
}

test "changing a collection runs only on the caller's own root, and the page may call it" {
    assert OPERATIONS["ChangeCollection"].runs == OWN;
    assert OPERATIONS["GetCollection"].runs == OWN;
    assert "ChangeCollection" in page_walkers() and "GetCollection" in page_walkers();
}

test "a refused removal names the card, not its oracle id" {
    _change(ALICE, "Sol Ring", 1);
    refused = _change(ALICE, "Sol Ring", 4, MODE_REMOVE);
    assert refused is not None;
    assert "Sol Ring" in refused.message;
}

test "the history keeps every change, however many" {
    for i in range(130) {
        _change(BOB, "Mountain", 1, reason=f"change {i}");
    }
    assert len([n for n in _collection(BOB).history if n.name == "Mountain"]) == 130;
}

test "a refused change writes nothing, not even an empty collection" {
    carol = "user_test_collection_carol";
    refused = _change(carol, "Shock", 1, MODE_REMOVE);
    assert refused is not None and refused.code == "refused-change";
    kept = call_function(carol, lambda () -> object { return len([root-->[?:Collection]]); });
    assert kept == 0;
}

"""`caller` imports `text` (default format `text`) into their collection; the result they read."""
def _import(caller: str, text: str, format: str = "text") -> ImportCollectionResult {
    return perform(caller, ImportCollection(format=format, text=text)).reports[0] as ImportCollectionResult;
}

test "importing a pasted list adds its totals, summing repeats across zones, and logs each card as imported" {
    done = _import(ALICE, "4 Lightning Bolt\n2 Shock\n\nSideboard\n1 Lightning Bolt\n");
    assert done.unresolved == [];
    assert _count(ALICE, "Lightning Bolt") == 5;
    assert _count(ALICE, "Shock") == 2;
    notes = [n for n in _collection(ALICE).history if n.reason == REASON_IMPORTED];
    assert sorted([(n.name, n.before, n.after) for n in notes]) == [("Lightning Bolt", 0, 5), ("Shock", 0, 2)];
}

test "an import adds to the counts already held and never lowers one" {
    _change(BOB, "Counterspell", 3);
    _import(BOB, "1 Counterspell\n");
    assert _count(BOB, "Counterspell") == 4;
    _import(BOB, "1 Shock\n");
    assert _count(BOB, "Counterspell") == 4;
    assert [n for n in _collection(BOB).history if n.name == "Counterspell"][-1].reason == REASON_IMPORTED;
}

test "names that resolve to no card are reported and the rest of the list is still added" {
    done = _import(ALICE, "1 Goblin Guide\n3 Not A Real Card\n");
    assert len(done.unresolved) == 1 and "Not A Real Card" in done.unresolved[0];
    assert _count(ALICE, "Goblin Guide") == 1;
}

test "a Maybeboard header is ignored like any other zone header" {
    _import(ALICE, "1 Llanowar Elves\n\nMaybeboard\n1 Llanowar Elves\n");
    assert _count(ALICE, "Llanowar Elves") == 2;
}

test "an import where nothing resolves leaves no collection behind" {
    dan = "user_test_collection_dan";
    done = _import(dan, "2 Not A Real Card\n");
    assert done.unresolved != [];
    assert done.collection.cards == [] and done.collection.history == [];
    kept = call_function(dan, lambda () -> object { return len([root-->[?:Collection]]); });
    assert kept == 0;
}

test "an unknown list format reports a walker error and adds nothing" {
    done = perform(ALICE, ImportCollection(format="nope", text="1 Shock\n")).reports[0];
    assert isinstance(done, WalkerError);
    assert done.code == "unknown-list-format";
}

test "each deck import format reads into the collection" {
    arena = _import(BOB, "Deck\n2 Shock (M21) 100\n", "arena");
    assert arena.unresolved == [];
    assert _count(BOB, "Shock") == 2;
    moxfield = _import(BOB, "1 Goblin Guide (M21) 5\n", "moxfield");
    assert moxfield.unresolved == [];
    assert _count(BOB, "Goblin Guide") == 1;
    mtgdeck = _import(BOB, '{"schema": "mtgdeck/1", "name": "x", "format": "modern", "zones": {"main": [{"name": "Goblin Guide", "count": 1}], "maybeboard": [{"name": "Goblin Guide", "count": 2}]}}', "mtgdeck1");
    assert mtgdeck.unresolved == [];
    assert _count(BOB, "Goblin Guide") == 4;
}

# Keep last: `perform` registers the shared root for this process, and `jac test`
# gives each test an empty graph, so the next file's tests (which spawn on a bare
# root) would look for a shared root that no longer exists.
test "the collection tests leave no shared root registered for the next test file" {
    Jac.set_shared_root_resolver(None);
    STARTED_FOR_GUEST.clear();
    assert Jac.shared_root_id() is None;
}
