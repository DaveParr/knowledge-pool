"""Seam A for the quest list: `perform` called in process as users.

The quest list is worked out on read from a user's decks and collection, so
every behaviour is checked as what a user reads, never as stored data.
"""

import os;
import from pathlib { Path }
import from catalog.ingest { build, load_atomic, load_oracle_tags }
import catalog.store as store;
import from walker_errors { WalkerError }
import from jaclang { JacRuntime as Jac }
import from graph_runner { STARTED_FOR_GUEST }
import from deck_operations { perform }
import from decks { CreateDeck, EditDeck }
import from collection { ChangeCollection, GetCollection, ListUsers }
import from collection_views { CollectionView, UserSummary, QuestListView }
import from quest_list { GetQuestList, GotQuest, GetOtherQuestList }
import from graph_runner { call_function }
import from profile { save_display_name }

glob CATALOG: Path = Path("data/test_quest_list_catalog.sqlite"),
     ALICE: str = "user_test_quest_alice",
     BOB: str = "user_test_quest_bob";

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

"""`caller` makes a deck holding `cards`, a list of (card name, zone, count); its id."""
def _deck(caller: str, name: str, cards: list[tuple[str, str, int]]) -> str {
    made = perform(caller, CreateDeck(name=name, format="modern")).reports[0];
    deck_id = jid(made);
    changes = [{"oracle_id": _oid(n), "count": c, "zone": z, "reason": "test"} for (n, z, c) in cards];
    perform(caller, EditDeck(deck_id=deck_id, changes=changes));
    return deck_id;
}

"""`caller` owns `count` copies of `name`."""
def _own(caller: str, name: str, count: int) {
    perform(caller, ChangeCollection(oracle_id=_oid(name), count=count, mode="add", reason="test"));
}

"""`caller`'s quest list as a dict of card name to copies still needed."""
def _quest(caller: str) -> dict[str, int] {
    view = perform(caller, GetQuestList()).reports[0] as QuestListView;
    return {l.name: l.count for l in view.lines};
}

test "the quest list needs, per card, the largest count any one deck needs minus the collection's count" {
    _deck(ALICE, "Burn", [("Lightning Bolt", "main", 4), ("Shock", "main", 2)]);
    _deck(ALICE, "Pile", [("Lightning Bolt", "main", 2), ("Shock", "sideboard", 3)]);
    _own(ALICE, "Lightning Bolt", 1);
    assert _quest(ALICE) == {"Lightning Bolt": 3, "Shock": 3};
}

test "a card held only in a maybeboard is not on the quest list" {
    _deck(ALICE, "Maybe", [("Counterspell", "maybeboard", 4), ("Lightning Bolt", "main", 1)]);
    assert _quest(ALICE) == {"Lightning Bolt": 1};
}

"""`caller`'s quest list view."""
def _view(caller: str) -> QuestListView {
    return perform(caller, GetQuestList()).reports[0] as QuestListView;
}

test "each line lists the decks that need the card with how many each needs" {
    burn = _deck(ALICE, "Burn", [("Lightning Bolt", "main", 4), ("Shock", "main", 2)]);
    pile = _deck(ALICE, "Pile", [("Lightning Bolt", "sideboard", 2), ("Lightning Bolt", "main", 1)]);
    line = [l for l in _view(ALICE).lines if l.name == "Lightning Bolt"][0];
    assert sorted([(d.deck_id, d.name, d.count) for d in line.decks]) == sorted([(burn, "Burn", 4), (pile, "Pile", 3)]);
    assert line.count == 4;
    shock = [l for l in _view(ALICE).lines if l.name == "Shock"][0];
    assert [(d.deck_id, d.count) for d in shock.decks] == [(burn, 2)];
}

test "getting some copies from the quest list reduces the line, adds them to the collection and logs the quest list as the reason" {
    _deck(ALICE, "Burn", [("Lightning Bolt", "main", 4)]);
    done = perform(ALICE, GotQuest(oracle_id=_oid("Lightning Bolt"), count=3));
    assert {l.name: l.count for l in (done.reports[0] as QuestListView).lines} == {"Lightning Bolt": 1};
    assert _quest(ALICE) == {"Lightning Bolt": 1};
    held = perform(ALICE, GetCollection()).reports[0] as CollectionView;
    assert [(l.name, l.count) for l in held.cards] == [("Lightning Bolt", 3)];
    assert "quest list" in held.history[-1].reason.lower();
}

test "the quest list follows a deck edit and a collection change on the next read, and a line is gone once the collection covers it" {
    deck = _deck(ALICE, "Burn", [("Lightning Bolt", "main", 2)]);
    assert _quest(ALICE) == {"Lightning Bolt": 2};
    perform(ALICE, EditDeck(deck_id=deck, changes=[{"oracle_id": _oid("Shock"), "count": 1, "zone": "main", "reason": "test"}]));
    assert _quest(ALICE) == {"Lightning Bolt": 2, "Shock": 1};
    _own(ALICE, "Lightning Bolt", 2);
    assert _quest(ALICE) == {"Shock": 1};
}

test "getting a card that is not in the catalogue is refused with refused-change and writes nothing" {
    done = perform(ALICE, GotQuest(oracle_id="no-such-oracle-id", count=1));
    assert isinstance(done.reports[0], WalkerError);
    assert (done.reports[0] as WalkerError).code == "refused-change";
    assert (perform(ALICE, GetCollection()).reports[0] as CollectionView).cards == [];
}

"""The handle of the user `name` as `caller` sees it in the listing."""
def _handle_of(caller: str, name: str) -> str {
    call_function(BOB, lambda () -> object { save_display_name(name); return None; });
    listed = perform(caller, ListUsers()).reports[0] as list[UserSummary];
    return [u.handle for u in listed if u.name == name][0];
}

test "a user reads another user's quest list by handle, from that user's decks and collection, not their own" {
    _deck(BOB, "Control", [("Counterspell", "main", 3)]);
    _own(BOB, "Counterspell", 1);
    _deck(ALICE, "Burn", [("Lightning Bolt", "main", 4)]);
    handle = _handle_of(ALICE, "Bob Quester");
    seen = perform(ALICE, GetOtherQuestList(handle=handle)).reports[0] as QuestListView;
    assert {l.name: l.count for l in seen.lines} == {"Counterspell": 2};
    assert _quest(ALICE) == {"Lightning Bolt": 4};
}

test "the quest list exports as a line list, a count and a name per line, and only when asked for" {
    _deck(ALICE, "Burn", [("Lightning Bolt", "main", 4), ("Shock", "main", 2)]);
    _own(ALICE, "Lightning Bolt", 1);
    exported = perform(ALICE, GetQuestList(export=True)).reports[0] as QuestListView;
    assert exported.text.splitlines() == ["3 Lightning Bolt", "2 Shock"];
    assert _view(ALICE).text == "";
}

test "another user's quest list exports the same way" {
    _deck(BOB, "Control", [("Counterspell", "main", 3)]);
    handle = _handle_of(ALICE, "Bob Quester");
    exported = perform(ALICE, GetOtherQuestList(handle=handle, export=True)).reports[0] as QuestListView;
    assert exported.text.splitlines() == ["3 Counterspell"];
}

# Keep last: `perform` registers the shared root for this process, and `jac test`
# gives each test an empty graph, so the next file's tests would look for a
# shared root that no longer exists.
test "the quest list tests leave no shared root registered for the next test file" {
    Jac.set_shared_root_resolver(None);
    STARTED_FOR_GUEST.clear();
    assert Jac.shared_root_id() is None;
}
