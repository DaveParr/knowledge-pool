"""Seam A: the runner, called in process with caller ids.

Every deck action runs as a caller on that caller's own root. These tests
call the runner as two users and check what each one sees and can change.
They also guard Jac itself: if a Jac upgrade reopens a read or write across
users, or lets a user change a shared card, a test here fails.
"""

import logging;
import os;
import from logging.handlers { BufferingHandler }
import from unittest.mock { patch }
import from uuid { UUID, uuid4 }
import from jaclang { JacRuntime as Jac }
import from jaclang.runtime.constructs { Anchor, WalkerArchetype }
import from jaclang.runtime.exceptions { WriteConflict }
import from jaclang.server.session { Session }
import from pathlib { Path }
import from catalog.ingest { build, load_atomic, load_oracle_tags }
import catalog.store as store;
import from decks { Deck, DeckView, CreateDeck, ListDecks, ListOtherDecks, CopyOtherDeck, GetDeck, AddCard, SetCardCount, RemoveCard, SetDeckFormat, RenameDeck, EditDeck, DeckSummary, holdings }
import from profile { save_display_name, UNKNOWN_USER }
import from deck_io { DeckExport, ExportResult }
import from walker_errors { WalkerError }
import from deck_operations { perform, page_walkers, OPERATIONS, OWN, OWNER, FLOW }
import from graph_runner { refresh_cards, guest_root_id, user_root_id, run_walker, run_read, list_other_decks, copy_deck, owns_deck, call_function, run_as_guest, in_context, start, request_caller, check_bind, LOCAL_USER, RERUNS, CallFailed, LOG }
import from cards { Card, RefreshCards, new_card, card_nodes_for, catalogue_version }
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
    first = perform(caller, w).reports[0];
    return first.code if isinstance(first, WalkerError) else "";
}

test "changing another user's deck answers not-your-deck, and an id that names no deck answers no-such-deck" {
    alices = _new_deck(ALICE, "Alice's change-guarded deck");
    assert _error_code(ALICE, GetDeck(deck_id=alices)) == "";
    bolt = store.find_by_name("Lightning Bolt")["oracle_id"] as str;
    assert _error_code(BOB, AddCard(deck_id=alices, oracle_id=bolt)) == "not-your-deck";
    assert _error_code(BOB, SetDeckFormat(deck_id=alices, format="modern")) == "not-your-deck";
    assert _error_code(BOB, AddCard(deck_id=str(uuid4()), oracle_id=bolt)) == "no-such-deck";
    assert _error_code(BOB, AddCard(deck_id="not an id", oracle_id=bolt)) == "no-such-deck";
    view = run_walker(ALICE, GetDeck(deck_id=alices)).reports[0] as DeckView;
    assert view.cards == [];
}

test "the not-your-deck message points to copying" {
    alices = _new_deck(ALICE, "Alice's copy-pointer deck");
    bolt = store.find_by_name("Lightning Bolt")["oracle_id"] as str;
    err = run_walker(BOB, AddCard(deck_id=alices, oracle_id=bolt)).reports[0] as WalkerError;
    assert "copy" in err.message.lower();
}

test "a card id or a root id is no deck: it answers no-such-deck, never not-your-deck" {
    alices = _deck_with(ALICE, "Alice's non-deck-id deck", "Shock");
    card_id = _card_ids(ALICE, alices)[0];
    root_id = user_root_id(ALICE);
    bolt = store.find_by_name("Lightning Bolt")["oracle_id"] as str;
    assert _error_code(BOB, AddCard(deck_id=card_id, oracle_id=bolt)) == "no-such-deck";
    assert _error_code(BOB, AddCard(deck_id=root_id, oracle_id=bolt)) == "no-such-deck";
}

test "a deck another user can read answers not-your-deck to a change: only the owner's root counts" {
    alices = _new_deck(ALICE, "Alice's readable deck");
    call_function(ALICE, lambda () -> object { grant(jobj(alices), level=AccessLevel.READ); return None; });
    seen = call_function(BOB, lambda () -> object { return jobj(alices); });
    assert isinstance(seen, Deck);  # Jac lets Bob read it now
    bolt = store.find_by_name("Lightning Bolt")["oracle_id"] as str;
    assert _error_code(BOB, AddCard(deck_id=alices, oracle_id=bolt)) == "not-your-deck";
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

"""Whether `change` as `caller` was refused: Jac raised, the runner rolled the
call back and gave the caller its internal error."""
def _refused(caller: str, change: Callable[[], object]) -> bool {
    try {
        call_function(caller, change);
    } except CallFailed as failed {
        return failed.error.code == "internal-error";
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

"""Call `f` in process as the guest, on the guest's root, as the app's own
work on the shared cards does."""
def _as_guest(f: Callable[[], object]) -> object {
    start();
    return in_context(guest_root_id(), f);
}

"""The ids of the two Card nodes the guest makes for the card `name`, in the
order made. Ids are random, so which is lowest is left to chance: a test
that compares them must use `min`, never the order made."""
def _duplicate_cards(name: str) -> list[str] {
    oid = _oracle_id(name);
    c = store.get_card(oid) as JsonObject;
    return [
        _as_guest(lambda () -> object { return jid(new_card(root, oid, c)); }) as str
        for _ in range(2)
    ];
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
    _as_guest(rewrite);
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

"""Run `check` with every commit to the graph failing, with the error
`failure()`, until the runner has rolled back `failures` times: the first
`failures` tries at a call conflict. Return what `check` returned and how
many failing tries were left unused."""
def _with_failing_commits(failures: int, failure: Callable[[], Exception], check: Callable[[], object]) -> tuple[object, int] {
    # Set up the guest and both users first: their roots are committed too.
    start();
    user_root_id(ALICE);
    user_root_id(BOB);
    real_commit = Session.commit;
    real_abort = Session.abort;
    left = failures;
    def flaky_commit(mem: Session, anchor: Anchor | None = None) {
        if left > 0 {
            raise failure();
        }
        real_commit(mem, anchor);
    }
    def counted_abort(mem: Session) {
        left = max(0, left - 1);
        real_abort(mem);
    }
    with patch.object(Session, "commit", flaky_commit), patch.object(Session, "abort", counted_abort) {
        done = check();
    }
    return (done, left);
}

def _write_conflict -> Exception {
    return WriteConflict(anchor_id=uuid4());
}

"""A Postgres serialization failure as the driver raises it: SQLSTATE 40001
in the error's fields."""
def _serialization_failure -> Exception {
    return RuntimeError({"C": "40001", "M": "could not serialize access due to concurrent update"});
}

"""Create deck `name` as Alice while the first `failures` tries meet the
error `failure()`, and check the deck was made, and made only once: each
failed try was rolled back before the re-run."""
def _lands_once(name: str, failures: int, failure: Callable[[], Exception]) {
    (made, unused_failures) = _with_failing_commits(
        failures, failure, lambda () -> object { return run_walker(ALICE, CreateDeck(name=name)).reports[0]; }
    );
    assert unused_failures == 0;
    assert isinstance(made, Deck);
    assert _deck_names(ALICE).count(name) == 1;
}

test "a call whose commit hits a write conflict is rolled back and re-run, and lands once" {
    _lands_once("Alice's conflicted deck", RERUNS, _write_conflict);
}

test "a serialization failure at commit is re-run like a write conflict" {
    _lands_once("Alice's serialized deck", 1, _serialization_failure);
}

test "a call still conflicting after its re-runs gets try-again, and writes nothing" {
    name = "Alice's given-up deck";
    (code, unused_failures) = _with_failing_commits(
        RERUNS + 1, _write_conflict, lambda () -> object { return _error_code(ALICE, CreateDeck(name=name)); }
    );
    assert unused_failures == 0;
    assert code == "try-again";
    assert name not in _deck_names(ALICE);
}

test "a function call still conflicting after its re-runs fails with try-again" {
    (code, _) = _with_failing_commits(
        RERUNS + 1, _write_conflict, lambda () -> object {
            try {
                call_function(ALICE, lambda () -> object { return None; });
            } except CallFailed as failed {
                return failed.error.code;
            }
            return "";
        }
    );
    assert code == "try-again";
}

test "an error that is not a conflict is not re-run" {
    (_, unused_failures) = _with_failing_commits(
        2, lambda () -> Exception { return RuntimeError("not a conflict"); }, lambda () -> object {
            try {
                run_walker(ALICE, ListDecks());
            } except RuntimeError {}
            return None;
        }
    );
    assert unused_failures == 1;
}

test "the guest's own work that cannot finish raises, so work at start fails the start" {
    (_, unused_failures) = _with_failing_commits(
        RERUNS + 1, _write_conflict, lambda () -> object {
            try {
                run_as_guest(ListDecks());
                assert False, "the guest's failed work returned";
            } except CallFailed as failed {
                assert failed.error.code == "try-again";
            }
            return None;
        }
    );
    assert unused_failures == 0;
}

"""Renames any deck by id, with none of the app's ownership checks: a stand-in
for a walker whose check passed but whose write Jac still refuses."""
walker RenameAnyDeck {
    has deck_id: str,
        name: str;

    can rename with Root entry {
        deck = jobj(self.deck_id) as Deck;
        deck.name = self.name;
        report deck.name;
    }
}

test "a write Jac refuses after the app's checks gives an internal error, logged with the walker and caller" {
    alices = _new_deck(ALICE, "Alice's refused-write deck");
    call_function(ALICE, lambda () -> object { grant(jobj(alices), level=AccessLevel.READ); return None; });
    seen = BufferingHandler(100);
    LOG.addHandler(seen);
    try {
        first = run_walker(BOB, RenameAnyDeck(deck_id=alices, name="Renamed by Bob")).reports[0];
    } finally {
        LOG.removeHandler(seen);
    }
    assert isinstance(first, WalkerError);
    assert first.code == "internal-error";
    assert alices not in first.message;
    logged = [r.getMessage() for r in seen.buffer];
    assert any("RenameAnyDeck" in line and BOB in line for line in logged), logged;
    view = run_walker(ALICE, GetDeck(deck_id=alices)).reports[0] as DeckView;
    assert view.name == "Alice's refused-write deck";
}

"""Rebuild the runner's catalogue with Lightning Bolt's rules text set to
`text`, as a new MTGJSON build would, and reopen it."""
def _rebuild_catalogue(text: str) {
    atomic: dict[str, any] = load_atomic(Path("tests/fixtures/atomic_small.json"));
    face: dict[str, any] = atomic["data"]["Lightning Bolt"][0] as dict[str, any];
    face["text"] = text;
    build(atomic, CATALOG, tags=load_oracle_tags(Path("tests/fixtures/oracle_tags_small.jsonl")));
    store.reset();
}

"""Put the runner's catalogue back as the fixture has it."""
def _restore_catalogue {
    build(
        load_atomic(Path("tests/fixtures/atomic_small.json")),
        CATALOG,
        tags=load_oracle_tags(Path("tests/fixtures/oracle_tags_small.jsonl"))
    );
    store.reset();
}

"""The rules text on the one Card node for card `name`."""
def _card_text(name: str) -> str {
    oid = _oracle_id(name);
    return _as_guest(
        lambda () -> object { return min(card_nodes_for(root, oid), key=jid).text; }
    ) as str;
}

"""Overwrite the rules text of the Card node for `name`, as a stale copy has it."""
def _make_stale(name: str, text: str) {
    oid = _oracle_id(name);
    _as_guest(lambda () -> object { min(card_nodes_for(root, oid), key=jid).text = text; return None; });
}

test "the first start refreshes the card nodes and records the catalogue version" {
    _deck_with(ALICE, "Alice's first-start deck", "Lightning Bolt");
    _make_stale("Lightning Bolt", "Stale text.");
    assert refresh_cards();
    assert _card_text("Lightning Bolt") != "Stale text.";
}

test "a start with the same catalogue version skips the refresh" {
    _deck_with(ALICE, "Alice's skipped deck", "Lightning Bolt");
    assert refresh_cards();
    _make_stale("Lightning Bolt", "Stale text.");
    assert not refresh_cards();
    assert _card_text("Lightning Bolt") == "Stale text.";
}

test "a start with a new catalogue refreshes the card nodes, and skips again after" {
    _deck_with(ALICE, "Alice's new-build deck", "Lightning Bolt");
    assert refresh_cards();
    try {
        _rebuild_catalogue("Lightning Bolt deals 9 damage to any target.");
        assert refresh_cards();
        assert _card_text("Lightning Bolt") == "Lightning Bolt deals 9 damage to any target.";
        assert not refresh_cards();
    } finally {
        _restore_catalogue();
    }
}

test "the refresh runs in batches, and every card node is brought up to date" {
    for name in ["Lightning Bolt", "Counterspell", "Shock"] {
        _deck_with(ALICE, f"Alice's {name} batch deck", name);
        _make_stale(name, "Stale text.");
    }
    assert refresh_cards(batch=2);
    for name in ["Lightning Bolt", "Counterspell", "Shock"] {
        assert _card_text(name) != "Stale text.";
    }
}

test "a refresh that fails fails the start, and the next start runs it again" {
    _deck_with(ALICE, "Alice's failed-refresh deck", "Lightning Bolt");
    (failed, _) = _with_failing_commits(
        RERUNS + 1, _write_conflict, lambda () -> object {
            try {
                refresh_cards();
            } except CallFailed {
                return True;
            }
            return False;
        }
    );
    assert failed;
    assert refresh_cards();
}

test "the refresh warns, naming the oracle id of each card with more than one node" {
    _duplicate_cards("Counterspell");
    _deck_with(ALICE, "Alice's single-card deck", "Lightning Bolt");
    with patch.object(LOG, "warning") as warned {
        assert refresh_cards();
    }
    messages = [str(call.args) for call in warned.call_args_list];
    assert any(_oracle_id("Counterspell") in m for m in messages);
    assert not any(_oracle_id("Lightning Bolt") in m for m in messages);
}

test "the refresh logs the catalogue version, whether it ran or not" {
    _deck_with(ALICE, "Alice's logged deck", "Lightning Bolt");
    version = catalogue_version();
    with patch.object(LOG, "info") as told {
        assert refresh_cards();
        assert not refresh_cards();
    }
    messages = [str(call.args) for call in told.call_args_list];
    assert len(messages) == 2;
    assert all(version in m for m in messages);
}

test "a refresh with no duplicate cards logs no warning" {
    _deck_with(ALICE, "Alice's no-duplicate deck", "Lightning Bolt");
    with patch.object(LOG, "warning") as warned {
        assert refresh_cards();
    }
    assert warned.call_count == 0;
}


# ---- Other users' decks: reading and copying -----------------------------

"""`caller`'s deck `name` holding a Shock (main, with a role, a tag and a lock) and a Lightning Bolt (sideboard)."""
def _annotated_deck(caller: str, name: str) -> str {
    deck_id = _new_deck(caller, name);
    shock = _oracle_id("Shock");
    bolt = _oracle_id("Lightning Bolt");
    done = run_walker(
        caller,
        EditDeck(
            deck_id=deck_id,
            changes=[
                {"oracle_id": shock, "count": 3, "zone": "main", "reason": "cheap burn"},
                {"oracle_id": bolt, "count": 2, "zone": "sideboard", "reason": "backup burn"}
            ]
        )
    );
    assert done.reports[0].rejected == [];
    return deck_id;
}

"""Give `caller`'s deck `deck_id` its entry metadata on the Shock, as the deck's owner."""
def _annotate_shock(caller: str, deck_id: str) {
    call_function(
        caller,
        lambda () -> object {
            for (e, c) in holdings(jobj(deck_id) as Deck) {
                if c.name == "Shock" {
                    e.roles = ["removal"];
                    e.tags = ["burn"];
                    e.locked = True;
                    e.reason = "kills small creatures";
                }
            }
            return None;
        }
    );
}

test "a user reads another user's deck as the owner, with its cards, history and notes" {
    alices = _annotated_deck(ALICE, "Alice's readable-by-all deck");
    _annotate_shock(ALICE, alices);
    view = run_read(BOB, alices, GetDeck(deck_id=alices)).reports[0] as DeckView;
    assert view.name == "Alice's readable-by-all deck";
    assert [(l.name, l.zone, l.count) for l in view.cards] == [("Shock", "main", 3), ("Lightning Bolt", "sideboard", 2)];
    shock = [l for l in view.cards if l.name == "Shock"][0];
    assert shock.roles == ["removal"] and shock.locked and shock.reason == "kills small creatures";
    assert len(view.history) == 2;
}

test "a read of another user's deck gives Bob no grant: his own lookup still finds nothing" {
    alices = _new_deck(ALICE, "Alice's no-grant deck");
    run_read(BOB, alices, GetDeck(deck_id=alices));
    assert call_function(BOB, lambda () -> object { return jobj(alices); }) is None;
}

test "a read of another user's deck exports it too" {
    alices = _annotated_deck(ALICE, "Alice's exportable deck");
    out = run_read(BOB, alices, DeckExport(deck_id=alices, format="text")).reports[0] as ExportResult;
    assert "Shock" in out.content;
}

test "a read of an id that names no deck answers no-such-deck" {
    assert run_read(BOB, str(uuid4()), GetDeck(deck_id=str(uuid4()))).reports[0].code == "no-such-deck";
    assert run_read(BOB, "not an id", GetDeck(deck_id="not an id")).reports[0].code == "no-such-deck";
}

test "a read with no caller is refused" {
    alices = _new_deck(ALICE, "Alice's no-caller deck");
    refused = False;
    try {
        run_read(None, alices, GetDeck(deck_id=alices));
    } except PermissionError {
        refused = True;
    }
    assert refused;
}

"""What a deck view shows of its deck, as plain values to compare."""
def _shape(view: DeckView) -> tuple[object, ...] {
    return (
        view.id, view.name, view.format,
        [(l.name, l.zone, l.count, l.roles, l.tags, l.locked, l.reason) for l in view.cards],
        [(n.name, n.zone, n.before, n.after, n.reason) for n in view.history]
    );
}

"""The one copy a user made of deck `deck_id`, as its view."""
def _copy_view(caller: str, deck_id: str) -> DeckView {
    return copy_deck(caller, deck_id).reports[0] as DeckView;
}

test "copying another user's deck makes the copier's own deck named '<name> (copy)', with cards, zones, counts and format" {
    alices = _annotated_deck(ALICE, "Alice's burn deck");
    run_walker(ALICE, SetDeckFormat(deck_id=alices, format="modern"));
    copy = _copy_view(BOB, alices);
    assert copy.name == "Alice's burn deck (copy)";
    assert copy.format == "modern";
    assert [(l.name, l.zone, l.count) for l in copy.cards] == [("Shock", "main", 3), ("Lightning Bolt", "sideboard", 2)];
    assert "Alice's burn deck (copy)" in _deck_names(BOB);
    assert copy.id != alices;
    assert _error_code(BOB, AddCard(deck_id=copy.id, oracle_id=_oracle_id("Shock"))) == "";
}

test "a copy carries the per-card notes: roles, tags, locked and reason" {
    alices = _annotated_deck(ALICE, "Alice's noted deck");
    _annotate_shock(ALICE, alices);
    copy = _copy_view(BOB, alices);
    shock = [l for l in copy.cards if l.name == "Shock"][0];
    assert shock.roles == ["removal"] and shock.tags == ["burn"] and shock.locked;
    assert shock.reason == "kills small creatures";
}

test "a copy starts its own history with one line saying it was copied" {
    alices = _annotated_deck(ALICE, "Alice's history deck");
    save_display_name_as(ALICE, "Alice Archer");
    copy = _copy_view(BOB, alices);
    assert len(copy.history) == 1;
    assert "copied" in copy.history[0].reason.lower();
    assert "Alice's history deck" in copy.history[0].reason;
}

"""Store `name` as `caller`'s display name."""
def save_display_name_as(caller: str, name: str) {
    call_function(caller, lambda () -> object { save_display_name(name); return None; });
}

test "copying leaves the original untouched" {
    alices = _annotated_deck(ALICE, "Alice's untouched deck");
    before = run_walker(ALICE, GetDeck(deck_id=alices)).reports[0] as DeckView;
    copy = _copy_view(BOB, alices);
    run_walker(BOB, AddCard(deck_id=copy.id, oracle_id=_oracle_id("Goblin Guide")));
    after = run_walker(ALICE, GetDeck(deck_id=alices)).reports[0] as DeckView;
    assert _shape(after) == _shape(before);
    assert _deck_names(ALICE).count("Alice's untouched deck") == 1;
    assert "Alice's untouched deck (copy)" not in _deck_names(ALICE);
}

test "a copy stays as it was when the original changes later" {
    alices = _annotated_deck(ALICE, "Alice's later-changed deck");
    copy = _copy_view(BOB, alices);
    run_walker(ALICE, AddCard(deck_id=alices, oracle_id=_oracle_id("Goblin Guide")));
    run_walker(ALICE, SetDeckFormat(deck_id=alices, format="commander"));
    again = run_walker(BOB, GetDeck(deck_id=copy.id)).reports[0] as DeckView;
    assert _shape(again) == _shape(copy);
}

test "a user can copy their own deck" {
    alices = _annotated_deck(ALICE, "Alice's self-copy deck");
    copy = _copy_view(ALICE, alices);
    assert copy.name == "Alice's self-copy deck (copy)";
    assert len(copy.cards) == 2;
}

test "copying an id that names no deck answers no-such-deck and makes nothing" {
    before = _deck_names(BOB);
    assert copy_deck(BOB, str(uuid4())).reports[0].code == "no-such-deck";
    assert _deck_names(BOB) == before;
}

"""The summaries of the decks `caller` can see that belong to other users."""
def _others(caller: str) -> list[DeckSummary] {
    return list_other_decks(caller);
}

test "listing other users' decks gives owner display name, deck name and format, and never the caller's own" {
    _new_deck(ALICE, "Alice's browsable deck");
    _new_deck(BOB, "Bob's own-browse deck");
    save_display_name_as(ALICE, "Alice Archer");
    seen = [(d.owner, d.name, d.format) for d in _others(BOB)];
    assert ("Alice Archer", "Alice's browsable deck", "standard") in seen;
    assert all(n != "Bob's own-browse deck" for (_, n, _) in seen);
    assert all(n != "Alice's browsable deck" for (_, n, _) in [(d.owner, d.name, d.format) for d in _others(ALICE)]);
}

test "an owner with no stored name shows as Unknown user" {
    carol = "user_test_carol_unnamed";
    _new_deck(carol, "Carol's unnamed-owner deck");
    mine = [d for d in _others(BOB) if d.name == "Carol's unnamed-owner deck"];
    assert len(mine) == 1 and mine[0].owner == UNKNOWN_USER;
}

test "a listed deck's id reads and copies" {
    _new_deck(ALICE, "Alice's listed-then-read deck");
    listed = [d for d in _others(BOB) if d.name == "Alice's listed-then-read deck"][0];
    assert run_read(BOB, listed.id, GetDeck(deck_id=listed.id)).reports[0].name == "Alice's listed-then-read deck";
    assert _copy_view(BOB, listed.id).name == "Alice's listed-then-read deck (copy)";
}

test "a user owns the decks they made, and no one else's, and no id that names no deck" {
    mine = _new_deck(ALICE, "Alice owns this");
    assert owns_deck(ALICE, mine);
    assert not owns_deck(BOB, mine);
    assert not owns_deck(ALICE, "not-a-deck");
    assert not owns_deck(ALICE, str(uuid4()));
}

test "the owner renames a deck: the name is trimmed, shows in the list and the history gets one line" {
    id = _new_deck(ALICE, "Alice's old name");
    view = run_walker(ALICE, RenameDeck(deck_id=id, name="  Alice's new name  ")).reports[0] as DeckView;
    assert view.name == "Alice's new name";
    assert view.history[-1].reason == "Renamed from Alice's old name to Alice's new name";
    assert "Alice's new name" in _deck_names(ALICE);
    assert "Alice's old name" not in _deck_names(ALICE);
}

test "another user cannot rename a deck: not-your-deck, and the name stays" {
    id = _new_deck(ALICE, "Alice's guarded name");
    assert _error_code(BOB, RenameDeck(deck_id=id, name="Bob's name")) == "not-your-deck";
    assert "Alice's guarded name" in _deck_names(ALICE);
    assert _error_code(BOB, RenameDeck(deck_id=str(uuid4()), name="x")) == "no-such-deck";
}

test "a blank name renames nothing and writes no history" {
    id = _new_deck(ALICE, "Alice's kept name");
    assert _error_code(ALICE, RenameDeck(deck_id=id, name="   ")) == "blank-name";
    view = run_walker(ALICE, GetDeck(deck_id=id)).reports[0] as DeckView;
    assert view.name == "Alice's kept name" and view.history == [];
}

test "a copy keeps its own name when the original is renamed" {
    id = _new_deck(ALICE, "Alice's original");
    copied = (copy_deck(BOB, id).reports[0] as DeckView).id;
    run_walker(ALICE, RenameDeck(deck_id=id, name="Alice's renamed"));
    bobs = run_walker(BOB, GetDeck(deck_id=copied)).reports[0] as DeckView;
    assert bobs.name == "Alice's original (copy)";
}

# Deck operations (`perform`), called as two users.

"""The first report of operation `w` performed by `caller`."""
def _op_first(caller: str, w: WalkerArchetype) -> object {
    return perform(caller, w).reports[0];
}

test "perform: a user reads and changes their own deck" {
    id = _new_deck(ALICE, "Alice's own deck");
    shock = _oracle_id("Shock");
    assert _error_code(ALICE, AddCard(deck_id=id, oracle_id=shock)) == "";
    view = _op_first(ALICE, GetDeck(deck_id=id)) as DeckView;
    assert [(l.name, l.zone, l.count) for l in view.cards] == [("Shock", "main", 1)];
    assert _error_code(ALICE, SetCardCount(deck_id=id, oracle_id=shock, count=3)) == "";
    assert _error_code(ALICE, RenameDeck(deck_id=id, name="Alice's renamed deck")) == "";
    assert _error_code(ALICE, SetDeckFormat(deck_id=id, format="modern")) == "";
    after = _op_first(ALICE, GetDeck(deck_id=id)) as DeckView;
    assert after.name == "Alice's renamed deck" and after.format == "modern" and after.cards[0].count == 3;
    assert _error_code(ALICE, RemoveCard(deck_id=id, oracle_id=shock)) == "";
    assert (_op_first(ALICE, GetDeck(deck_id=id)) as DeckView).cards == [];
    assert "Alice's renamed deck" in _deck_names(ALICE);
}

test "another user's deck is readable but not changeable: not-your-deck" {
    id = _new_deck(ALICE, "Alice's read-only-to-Bob deck");
    shock = _oracle_id("Shock");
    assert _error_code(ALICE, AddCard(deck_id=id, oracle_id=shock)) == "";
    seen = _op_first(BOB, GetDeck(deck_id=id)) as DeckView;
    assert seen.name == "Alice's read-only-to-Bob deck" and len(seen.cards) == 1;
    assert "Shock" in (_op_first(BOB, DeckExport(deck_id=id, format="text")) as ExportResult).content;
    assert _error_code(BOB, AddCard(deck_id=id, oracle_id=shock)) == "not-your-deck";
    assert _error_code(BOB, SetCardCount(deck_id=id, oracle_id=shock, count=4)) == "not-your-deck";
    assert _error_code(BOB, RemoveCard(deck_id=id, oracle_id=shock)) == "not-your-deck";
    assert _error_code(BOB, RenameDeck(deck_id=id, name="Bob's")) == "not-your-deck";
    assert _error_code(BOB, SetDeckFormat(deck_id=id, format="modern")) == "not-your-deck";
    assert _error_code(BOB, EditDeck(deck_id=id, changes=[])) == "not-your-deck";
    unchanged = _op_first(ALICE, GetDeck(deck_id=id)) as DeckView;
    assert unchanged.name == "Alice's read-only-to-Bob deck" and unchanged.cards[0].count == 1;
}

test "an id that names no deck answers no-such-deck, read or change" {
    nothing = str(uuid4());
    assert _error_code(BOB, GetDeck(deck_id=nothing)) == "no-such-deck";
    assert _error_code(BOB, GetDeck(deck_id="not an id")) == "no-such-deck";
    assert _error_code(BOB, AddCard(deck_id=nothing, oracle_id=_oracle_id("Shock"))) == "no-such-deck";
    assert _error_code(BOB, CopyOtherDeck(deck_id=nothing)) == "no-such-deck";
}

test "copying another user's deck makes the copier's own deck" {
    id = _new_deck(ALICE, "Alice's copyable deck");
    assert _error_code(ALICE, AddCard(deck_id=id, oracle_id=_oracle_id("Shock"))) == "";
    copy = _op_first(BOB, CopyOtherDeck(deck_id=id)) as DeckView;
    assert copy.name == "Alice's copyable deck (copy)" and copy.id != id;
    assert [(l.name, l.count) for l in copy.cards] == [("Shock", 1)];
    assert "Alice's copyable deck (copy)" in _deck_names(BOB);
    assert _error_code(BOB, AddCard(deck_id=copy.id, oracle_id=_oracle_id("Lightning Bolt"))) == "";
}

test "listing other users' decks shows theirs with the owner's name, never the caller's own" {
    _new_deck(ALICE, "Alice's listed deck");
    _new_deck(BOB, "Bob's unlisted-to-himself deck");
    call_function(ALICE, lambda () -> object { save_display_name("Alice Archer"); return None; });
    seen = [(d.owner, d.name) for d in _op_first(BOB, ListOtherDecks()) as list[DeckSummary]];
    assert ("Alice Archer", "Alice's listed deck") in seen;
    assert all(n != "Bob's unlisted-to-himself deck" for (_, n) in seen);
}

test "an operation outside the table is refused, and a format's rules are an ordinary operation" {
    refused = False;
    try {
        perform(ALICE, RefreshCards(offset=0, size=1));
    } except TypeError {
        refused = True;
    }
    assert refused;
    assert _error_code(ALICE, GetFormatRules(format="modern")) == "";
}

test "the table says how every operation runs, and flows name their function" {
    for (name, op) in OPERATIONS.items() {
        assert op.kind.__name__ == name;
        assert op.runs in [OWN, OWNER, FLOW];
        assert (op.across is not None) == (op.runs == FLOW);
    }
    assert set(page_walkers().keys()) == {n for (n, op) in OPERATIONS.items() if op.page};
}
