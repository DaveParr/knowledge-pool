"""Seam A: the runner, called in process with two users' ids.

Each test starts the runner (which registers the guest's root as Jac's shared
root) and unregisters it afterwards, so other walker tests keep their own root.
User ids are fresh per run, since the graph may outlive one run.

These tests are also the guard on Jac upgrades: they fail if Jac reopens a
cross-user read or write, or renames the private `_user_root` context field
the card catalogue switches to create a card as the guest.
"""

import os;
import from uuid { UUID, uuid4 }
import from pathlib { Path }
import from jaclang { JacRuntime as Jac }
import from catalog.ingest { build, load_atomic, load_oracle_tags }
import catalog.store as store;
import from runner {
    LOCK, LOCAL_USER, run_as, run_as_guest, run_walker, call_as, start, guest_root_id, user_root_id, mode,
    check_bind, request_caller
}
import from decks { Deck, DeckView, CreateDeck, ListDecks, GetDeck, SetDeckFormat, AddCard }
import from cards { Card, card_node }
import from legality { Format, format_node, GetFormatRules, FormatRules }
import from walker_errors { WalkerError }

glob CATALOG: Path = Path("data/test_runner_catalog.sqlite"),
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

"""Reports the id of the root it runs on."""
walker WhichRoot {
    has reports: list[str] = [];

    can show with Root entry {
        report jid(here);
    }
}

"""A user id no earlier run has used."""
def new_user(label: str) -> str {
    return f"{label}-{uuid4().hex}";
}

"""Run `work` with the runner started, then unregister the shared root."""
def with_runner(work: Callable[[], object]) {
    start();
    try {
        work();
    } finally {
        Jac.set_shared_root_resolver(None);
    }
}

"""Make a deck as `user` and return its id."""
def make_deck(user: str, name: str) -> str {
    return jid(run_as(user, CreateDeck(name=name)).reports[0] as Deck);
}

def deck_names(user: str) -> list[str] {
    return [d.name for d in run_as(user, ListDecks()).reports[0] as list[Deck]];
}

"""The only report of a walker run as `user`."""
def only_report(user: str, w: GetDeck | SetDeckFormat | AddCard) -> DeckView | WalkerError {
    reports = run_as(user, w).reports as list[DeckView | WalkerError];
    assert len(reports) == 1;
    return reports[0];
}

def error_code(found: DeckView | WalkerError) -> str {
    return found.code if isinstance(found, WalkerError) else "";
}

"""True when `work`, run as `user`, is refused by Jac."""
def refused(user: str, work: Callable[[], object]) -> bool {
    try {
        call_as(user, work);
    } except PermissionError {
        return True;
    }
    return False;
}

test "each user lists only their own decks" {
    with_runner(
        lambda {
            (a, b) = (new_user("a"), new_user("b"));
            make_deck(a, "A's burn");
            make_deck(b, "B's control");
            assert deck_names(a) == ["A's burn"];
            assert deck_names(b) == ["B's control"];
        }
    );
}

test "another user's deck id is no-such-deck for a read and a change, and the deck is unchanged" {
    with_runner(
        lambda {
            (a, b) = (new_user("a"), new_user("b"));
            deck_id = make_deck(a, "A's deck");
            assert error_code(only_report(b, GetDeck(deck_id=deck_id))) == "no-such-deck";
            assert error_code(only_report(b, SetDeckFormat(deck_id=deck_id, format="modern"))) == "no-such-deck";
            assert error_code(only_report(b, AddCard(deck_id=deck_id, oracle_id=BOLT, count=4))) == "no-such-deck";
            view = only_report(a, GetDeck(deck_id=deck_id)) as DeckView;
            assert view.format == "standard";
            assert view.cards == [];
        }
    );
}

test "a user cannot read under or write to another user's deck through Jac" {
    with_runner(
        lambda {
            (a, b) = (new_user("a"), new_user("b"));
            deck = run_as(a, CreateDeck(name="A's deck")).reports[0] as Deck;
            deck_id = jid(deck);
            a_root = user_root_id(a);
            assert call_as(b, lambda -> object { return jobj(deck_id); }) is None;
            assert call_as(b, lambda -> object { return jobj(a_root); }) is None;
            assert refused(b, lambda { deck.name = "Taken"; });
            assert refused(b, lambda { deck ++> Deck(name="Planted"); });
            assert refused(b, lambda { target = deck; del target; });
            assert deck_names(a) == ["A's deck"];
            assert (only_report(a, GetDeck(deck_id=deck_id)) as DeckView).name == "A's deck";
        }
    );
}

test "a card a user's deck first includes is owned by the guest" {
    with_runner(
        lambda {
            a = new_user("a");
            deck_id = make_deck(a, "A's deck");
            only_report(a, AddCard(deck_id=deck_id, oracle_id=BOLT, count=4));
            card = call_as(a, lambda -> Card | None { return card_node(BOLT); }) as Card;
            assert Jac.owner_of(card) == UUID(guest_root_id());
        }
    );
}

test "no user can change a shared card, and each user's deck can hold it" {
    with_runner(
        lambda {
            (a, b) = (new_user("a"), new_user("b"));
            for user in [a, b] {
                deck_id = make_deck(user, "Burn");
                view = only_report(user, AddCard(deck_id=deck_id, oracle_id=BOLT, count=4)) as DeckView;
                assert [(c.name, c.count) for c in view.cards] == [("Lightning Bolt", 4)];
            }
            for user in [a, b] {
                assert refused(user, lambda { (card_node(BOLT) as Card).name = "Hacked"; });
            }
            card = call_as(a, lambda -> Card | None { return card_node(BOLT); }) as Card;
            assert card.name == "Lightning Bolt";
        }
    );
}

test "the formats are the guest's: every user reads them and none changes them" {
    with_runner(
        lambda {
            a = new_user("a");
            rules = run_as(a, GetFormatRules(format="modern")).reports[0] as FormatRules;
            assert rules.copy_limit == 4;
            fmt = call_as(a, lambda -> Format | None { return format_node("modern"); }) as Format;
            assert Jac.owner_of(fmt) == UUID(guest_root_id());
            assert refused(a, lambda { (format_node("modern") as Format).copy_limit = 9; });
        }
    );
}

test "a call with no caller is refused, never run as the guest" {
    with_runner(
        lambda {
            for nobody in [None, ""] {
                try {
                    run_as(nobody, ListDecks());
                    assert False, "ran with no caller";
                } except PermissionError {}
            }
        }
    );
}

test "the guest entry runs on the guest's root, and a user's runs on their own" {
    with_runner(
        lambda {
            a = new_user("a");
            assert run_as_guest(WhichRoot()).reports == [guest_root_id()];
            assert run_as(a, WhichRoot()).reports == [user_root_id(a)];
            assert user_root_id(a) != guest_root_id();
        }
    );
}

test "a page function runs as the caller on the caller's root" {
    with_runner(
        lambda {
            a = new_user("a");
            assert call_as(a, lambda -> str { return jid(root); }) == user_root_id(a);
        }
    );
}

test "walkers run one at a time: the process-wide lock is held during a call" {
    with_runner(
        lambda {
            assert not LOCK.locked();
            assert call_as(new_user("a"), lambda -> bool { return LOCK.locked(); }) == True;
        }
    );
}

"""Run `work` with KP_MODE set to `value` (unset for None), then put it back."""
def in_mode(value: str | None, work: Callable[[], object]) {
    before = os.environ.get("KP_MODE");
    if value is None {
        os.environ.pop("KP_MODE", None);
    } else {
        os.environ["KP_MODE"] = value;
    }
    try {
        work();
    } finally {
        if before is None {
            os.environ.pop("KP_MODE", None);
        } else {
            os.environ["KP_MODE"] = before;
        }
    }
}

test "local mode is the default and every call runs as the local user" {
    with_runner(
        lambda {
            in_mode(
                None,
                lambda {
                    assert mode() == "local";
                    assert request_caller() == LOCAL_USER;
                    assert run_walker(WhichRoot()).reports == [user_root_id(LOCAL_USER)];
                }
            );
        }
    );
}

test "hosted mode has no caller yet, so a call is refused" {
    with_runner(
        lambda {
            in_mode(
                "hosted",
                lambda {
                    assert request_caller() is None;
                    try {
                        run_walker(ListDecks());
                        assert False, "ran with no caller";
                    } except PermissionError {}
                }
            );
        }
    );
}

test "an unknown mode is an error" {
    in_mode(
        "staging",
        lambda {
            try {
                mode();
                assert False, "accepted an unknown mode";
            } except ValueError {}
        }
    );
}

test "local mode refuses to bind anything but 127.0.0.1" {
    in_mode(
        "local",
        lambda {
            check_bind("127.0.0.1");
            for host in ["0.0.0.0", "localhost", "192.168.1.5"] {
                try {
                    check_bind(host);
                    assert False, f"local mode bound {host}";
                } except ValueError {}
            }
        }
    );
    in_mode("hosted", lambda { check_bind("0.0.0.0"); });
}
