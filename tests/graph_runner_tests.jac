"""Seam A: the runner, called in process with caller ids.

Every deck action runs as a caller on that caller's own root. These tests
call the runner as two users and check what each one sees and can change.
They also guard Jac itself: if a Jac upgrade reopens a read or write across
users, or lets a user change a shared card, a test here fails.
"""

import os;
import from uuid { UUID }
import from jaclang { JacRuntime as Jac }
import from jaclang.runtime.constructs { WalkerArchetype }
import from pathlib { Path }
import from catalog.ingest { build, load_atomic, load_oracle_tags }
import catalog.store as store;
import from decks { Deck, DeckView, CreateDeck, ListDecks, GetDeck, AddCard, holdings }
import from walker_errors { WalkerError }
import from graph_runner { guest_root_id, user_root_id, run_walker, call_function, run_as_guest, in_context, start, request_caller, check_bind, LOCAL_USER }
import from cards { Card, RefreshCards, new_card }
import from json_object { JsonObject }
import from legality { Format, FormatRules, GetFormatRules }

glob CATALOG: Path = Path("data/test_runner_catalog.sqlite"),
     ALICE: str = "user_test_alice",
     BOB: str = "user_test_bob";

with entry {
    build(
        load_atomic(Path("tests/fixtures/atomic_small.json")),
        CATALOG,
        tags=load_oracle_tags(Path("tests/fixtures/oracle_tags_small.jsonl"))
    );
    os.environ["KP_CATALOG"] = str(CATALOG.resolve());
    store.reset();
}

"""A new deck made by `caller`, as its id."""
def _new_deck(caller: str, name: str) -> str {
    made = run_walker(caller, CreateDeck(name=name)).reports[0] as Deck;
    return jid(made);
}

"""The names of the decks `caller` lists."""
def _deck_names(caller: str) -> list[str] {
    decks = run_walker(caller, ListDecks()).reports[0] as list[Deck];
    return [d.name for d in decks];
}

test "each user lists only the decks they made" {
    _new_deck(ALICE, "Alice's list deck");
    _new_deck(BOB, "Bob's list deck");
    assert "Alice's list deck" in _deck_names(ALICE);
    assert "Bob's list deck" not in _deck_names(ALICE);
    assert "Bob's list deck" in _deck_names(BOB);
    assert "Alice's list deck" not in _deck_names(BOB);
}

"""The walker error `caller` gets for walker `w`, or "" when it worked."""
def _error_code(caller: str, w: WalkerArchetype) -> str {
    first = run_walker(caller, w).reports[0];
    return first.code if isinstance(first, WalkerError) else "";
}

test "another user's deck id answers no-such-deck, to read or to change" {
    alices = _new_deck(ALICE, "Alice's private-to-change deck");
    assert _error_code(ALICE, GetDeck(deck_id=alices)) == "";
    assert _error_code(BOB, GetDeck(deck_id=alices)) == "no-such-deck";
    bolt = store.find_by_name("Lightning Bolt")["oracle_id"] as str;
    assert _error_code(BOB, AddCard(deck_id=alices, oracle_id=bolt)) == "no-such-deck";
    view = run_walker(ALICE, GetDeck(deck_id=alices)).reports[0] as DeckView;
    assert view.cards == [];
}

test "a deck another user can read still answers no-such-deck: only the owner's root counts" {
    alices = _new_deck(ALICE, "Alice's readable deck");
    call_function(ALICE, lambda () -> object { grant(jobj(alices), level=AccessLevel.READ); return None; });
    seen = call_function(BOB, lambda () -> object { return jobj(alices); });
    assert isinstance(seen, Deck);  # Jac lets Bob read it now
    assert _error_code(BOB, GetDeck(deck_id=alices)) == "no-such-deck";
}

"""The id of the oracle card `name`."""
def _oracle_id(name: str) -> str {
    return store.find_by_name(name)["oracle_id"] as str;
}

"""`caller`'s new deck holding one `card_name` in the main deck, as its id."""
def _deck_with(caller: str, deck_name: str, card_name: str) -> str {
    deck_id = _new_deck(caller, deck_name);
    assert _error_code(caller, AddCard(deck_id=deck_id, oracle_id=_oracle_id(card_name))) == "";
    return deck_id;
}

"""The ids of the Card nodes `caller`'s deck holds."""
def _card_ids(caller: str, deck_id: str) -> list[str] {
    return call_function(
        caller, lambda () -> object { return [jid(c) for (_, c) in holdings(jobj(deck_id) as Deck)]; }
    ) as list[str];
}

test "two users' decks hold the one shared card node" {
    alices = _deck_with(ALICE, "Alice's shock deck", "Shock");
    bobs = _deck_with(BOB, "Bob's shock deck", "Shock");
    shared = _card_ids(ALICE, alices);
    assert len(shared) == 1;
    assert _card_ids(BOB, bobs) == shared;
}

"""Whether `change` as `caller` was refused: Jac raised and nothing was written."""
def _refused(caller: str, change: Callable[[], object]) -> bool {
    try {
        call_function(caller, change);
    } except PermissionError {
        return True;
    }
    return False;
}

test "Jac hides another user's deck from a direct lookup" {
    alices = _new_deck(ALICE, "Alice's hidden deck");
    assert call_function(BOB, lambda () -> object { return jobj(alices); }) is None;
}

test "Jac refuses a write to another user's deck, even one they can read" {
    alices = _new_deck(ALICE, "Alice's guarded deck");
    call_function(ALICE, lambda () -> object { grant(jobj(alices), level=AccessLevel.READ); return None; });
    def rename -> object {
        deck = jobj(alices) as Deck;
        deck.name = "Renamed by Bob";
        return None;
    }
    assert _refused(BOB, rename);
    view = run_walker(ALICE, GetDeck(deck_id=alices)).reports[0] as DeckView;
    assert view.name == "Alice's guarded deck";
}

"""The id of the root that owns the node with id `node_id`, as `caller` sees it."""
def _owner_of(caller: str, node_id: str) -> str {
    return call_function(caller, lambda () -> object { return str(Jac.owner_of(jobj(node_id) as Card)); }) as str;
}

test "a card a user's deck first includes is owned by the guest, not the user" {
    # The card catalogue acts as the guest through Jac's private `_user_root`
    # context field; if Jac renames it, the user would own the card and this fails.
    alices = _deck_with(ALICE, "Alice's first-card deck", "Goblin Guide");
    card_id = _card_ids(ALICE, alices)[0];
    owner = UUID(_owner_of(ALICE, card_id));
    assert owner == UUID(guest_root_id());
    assert owner != UUID(user_root_id(ALICE));
}

test "no user can change a shared card, even one their own deck holds" {
    alices = _deck_with(ALICE, "Alice's bolt deck", "Lightning Bolt");
    card_id = _card_ids(ALICE, alices)[0];
    def rewrite -> object {
        card = jobj(card_id) as Card;
        card.text = "Changed by a user.";
        return None;
    }
    assert _refused(ALICE, rewrite);
    assert _refused(BOB, rewrite);
    view = run_walker(ALICE, GetDeck(deck_id=alices)).reports[0] as DeckView;
    assert view.cards[0].text == store.find_by_name("Lightning Bolt")["text"];
}

"""The ids of Card nodes the guest makes for the card `name`, in the order
made: at least two, and the first is not the lowest, so taking the first
match would pick a different card than taking the lowest id."""
def _duplicate_cards(name: str) -> list[str] {
    start();
    oid = _oracle_id(name);
    c = store.get_card(oid) as JsonObject;
    ids: list[str] = [];
    while len(ids) < 2 or min(ids) == ids[0] {
        ids.append(in_context(guest_root_id(), lambda () -> object { return jid(new_card(root, oid, c)); }) as str);
    }
    return ids;
}

test "with two cards for one oracle id, every deck holds the one with the lowest id" {
    lowest = min(_duplicate_cards("Counterspell"));
    alices = _deck_with(ALICE, "Alice's duplicate deck", "Counterspell");
    bobs = _deck_with(BOB, "Bob's duplicate deck", "Counterspell");
    assert _card_ids(ALICE, alices) == [lowest];
    assert _card_ids(BOB, bobs) == [lowest];
}

test "the guest can change a shared card in process, and every deck holding it sees the change" {
    alices = _deck_with(ALICE, "Alice's changed-card deck", "Llanowar Elves");
    bobs = _deck_with(BOB, "Bob's changed-card deck", "Llanowar Elves");
    card_id = _card_ids(ALICE, alices)[0];
    def rewrite -> object {
        card = jobj(card_id) as Card;
        card.text = "Changed by the guest.";
        return None;
    }
    in_context(guest_root_id(), rewrite);
    for (caller, deck_id) in [(ALICE, alices), (BOB, bobs)] {
        view = run_walker(caller, GetDeck(deck_id=deck_id)).reports[0] as DeckView;
        assert view.cards[0].text == "Changed by the guest.";
    }
}

test "no user can change a shared format" {
    def loosen -> object {
        formats = [root.shared-->[?:Format]];
        assert formats, "a user sees the shared formats";
        for f in formats {
            f.copy_limit = 99;
        }
        return None;
    }
    assert _refused(ALICE, loosen);
}

test "a call with no caller is refused, never run as the guest" {
    for nobody in [None, ""] {
        try {
            run_walker(nobody, ListDecks());
            assert False, "a call with no caller ran";
        } except PermissionError {}
    }
}

test "format rules come from the shared formats, adding nothing under the caller's root" {
    rules = run_walker(ALICE, GetFormatRules(format="modern")).reports[0] as FormatRules;
    assert rules.copy_limit == 4;
    assert call_function(ALICE, lambda () -> object { return [root-->[?:Format]]; }) == [];
}

"""Run `check` with `KP_MODE` set to `mode` ("" unsets it), then put it back."""
def _in_mode(mode: str, check: Callable[[], object]) -> object {
    was = os.environ.pop("KP_MODE", None);
    if mode {
        os.environ["KP_MODE"] = mode;
    }
    try {
        return check();
    } finally {
        os.environ.pop("KP_MODE", None);
        if was is not None {
            os.environ["KP_MODE"] = was;
        }
    }
}

"""Whether `check` raised ValueError."""
def _rejects(check: Callable[[], object]) -> bool {
    try {
        check();
    } except ValueError {
        return True;
    }
    return False;
}

test "local mode is the default, and every request runs as the local user" {
    assert _in_mode("", lambda () -> object { return request_caller(); }) == LOCAL_USER;
    assert _in_mode("local", lambda () -> object { return request_caller(); }) == LOCAL_USER;
}

test "hosted mode has no caller without a sign-in" {
    assert _in_mode("hosted", lambda () -> object { return request_caller(); }) is None;
}

test "an unknown mode is refused" {
    assert _rejects(lambda () -> object { return _in_mode("public", lambda () -> object { return request_caller(); }); });
}

test "local mode refuses to listen on anything but 127.0.0.1" {
    _in_mode("local", lambda () -> object { check_bind("127.0.0.1"); return None; });
    for host in ["0.0.0.0", "::", "192.168.1.10", "localhost"] {
        assert _rejects(lambda () -> object { return _in_mode("local", lambda () -> object { check_bind(host); return None; }); });
    }
}

test "the guest's own work runs on the guest's root: it can refresh the shared cards" {
    _deck_with(ALICE, "Alice's refresh deck", "Lightning Bolt");
    updated = run_as_guest(RefreshCards()).reports[0] as int;
    assert updated >= 1;
    assert "Alice's refresh deck" not in [d.name for d in run_as_guest(ListDecks()).reports[0] as list[Deck]];
}
