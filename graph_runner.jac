"""The runner: the one way the app's processes run deck work on the graph.

Every deck action runs as a caller (a user id) on that caller's own root,
from `ensure_user_root(<id>)`. `run_walker` and `call_function` are the
caller's entries; deck work reaches them through `perform` in
`deck_operations.jac`. `run_as_guest` is the second entry, for the app's own work on what every user shares (the cards
and the formats). Nothing a request reaches calls it.

No entry raises `CallFailed` to its caller. A call the runner could not finish
comes back as the walker error `try-again`, `busy` or `internal-error`: a walker entry
returns a copy of the walker whose one report it is, and an entry that returns
a value (`call_function`, `list_other_decks`) returns it in place of
the value. `in_context`, `attempt` and `start` are the primitives under the
entries and do raise it.

The guest root is registered as Jac's shared root (`root.shared`), so the
card catalogue and the formats are looked up there, never under the
caller's root. Before the first call, the guest creates the `Catalog` and
`Format` nodes and opens them to every user for reading.

One lock runs walkers one at a time across all users, so a call that never
finishes would stop every other. A call waits for the lock at most `LOCK_WAIT_S`:
after that the caller gets the walker error `busy` (HTTP 503). A call that holds
it longer than `SLOW_CALL_S` is logged with its name, caller and duration. A
call that fails is rolled back, so the next call starts clean.

Another process on the same database (the web app beside the MCP server) can
change what a call read before the call commits. On a write conflict or a
serialization failure the runner rolls the call back and re-runs it, up to
`RERUNS` times with a short random wait; after that the caller gets the
walker error `try-again`. Re-running is safe because walkers do nothing
outside the database before the commit: they read the card catalogue and
change the graph, nothing else. A walker must keep it that way.

A write Jac refuses reaches the runner only after the app's own checks have
passed (a deck the caller does not own answers `not-your-deck` before any
write), so it is an app fault: the call is rolled back, the caller gets the
walker error `internal-error`, and the log names the walker and the caller.

The app runs in one of two modes, set by `KP_MODE`: `local` (the default),
on a developer's machine, where every call runs as the fixed local user and
nothing binds anything but 127.0.0.1; or `hosted`, where the caller is the
`sub` of the bearer token the gatekeeper (`gatekeeper.jac`) verified. The runner
never works out who is asking: every entry takes the caller as an argument.
"""

import copy;
import io;
import logging;
import os;
import random;
import threading;
import time;
import from contextlib { redirect_stdout }
import from jaclang { JacRuntime as Jac }
import from jaclang.runtime.context { ExecutionContext }
import from jaclang.runtime.constants { Constants as Con }
import from jaclang.runtime.constructs { WalkerArchetype }
import from jaclang.runtime.exceptions { WriteConflict }
import from jaclang.server.session { transient_db_error }
import from jaclang.server.identity.user_manager { UserManager }
import from cards { open_catalog, RefreshCards, REFRESH_BATCH, catalogue_version, refreshed_version, record_refresh, duplicate_oracle_ids }
import from legality { open_formats }
import from collection { stamp_collection }
import from walker_errors { WalkerError }
import from profile { display_name }
import from collection_views { UserSummary, NO_SUCH_USER }
import from decks { DeckSummary, DeckView, CopySource, CopyDeck, deck_owner, deck_summaries }

glob APP_DIR: str = os.path.dirname(os.path.abspath(__file__)),
     LOCK: threading.RLock = threading.RLock(),
     LOCAL_USER: str = "local-user",
     LOOPBACK: str = "127.0.0.1",
     LOCAL: str = "local",
     HOSTED: str = "hosted",
     MODES: list[str] = [LOCAL, HOSTED],
     STARTED_FOR_GUEST: list[str] = [],
     USER_PAGE: int = 100,
     PERSON_ROLE: str = "user",
     LOCK_WAIT_S: float = 10.0,
     SLOW_CALL_S: float = 5.0,
     RERUNS: int = 3,
     RERUN_WAIT_S: tuple[float, float] = (0.01, 0.05),
     LOG: logging.Logger = logging.getLogger("knowledge_pool.runner");

"""A call the runner could not finish, rolled back: `error` is the walker
error the caller gets (`try-again` or `internal-error`). Raised by the runner's
primitives; every entry catches it and hands the error back."""
obj CallFailed(Exception) {
    has error: WalkerError;

    def postinit {
        super.init(self.error.message);
    }
}

def try_again -> WalkerError {
    return WalkerError(
        code="try-again", message="Someone else changed this at the same moment. Please try again."
    );
}

def internal_error -> WalkerError {
    return WalkerError(code="internal-error", message="Something went wrong on our side. Nothing was changed.");
}

def busy -> WalkerError {
    return WalkerError(code="busy", message="The server is busy with another call. Please try again in a moment.");
}

"""Hold the runner's lock for a `with`, waiting at most `LOCK_WAIT_S` for it: a call
that cannot get it raises `CallFailed` (`busy`) instead of queueing for ever behind
one that never finishes."""
obj runner_lock {
    has name: str = "",
        caller: str = "";

    def __enter__ -> None {
        if not LOCK.acquire(timeout=LOCK_WAIT_S) {
            LOG.warning("%s for caller %s gave up waiting %.0fs for the runner's lock", self.name, self.caller, LOCK_WAIT_S);
            raise CallFailed(error=busy());
        }
    }

    def __exit__(kind: object, value: object, trace: object) -> None {
        LOCK.release();
    }
}

"""Whether `e` means another writer got there first, so a re-run may succeed:
Jac's `WriteConflict`, or a serialization failure from Postgres."""
def is_write_conflict(e: Exception) -> bool {
    return isinstance(e, WriteConflict) or transient_db_error(e);
}

# A write Jac refuses fails the call and writes nothing, in every process.
# Jac reads JAC_STRICT_PERMISSIONS once, at import, so set the flag itself.
with entry {
    Jac.strict_permissions = True;
}

"""The app's mode, from `KP_MODE`: "local" (the default) or "hosted"."""
def app_mode -> str {
    mode = os.environ.get("KP_MODE", LOCAL);
    if mode not in MODES {
        raise ValueError(f"KP_MODE must be one of {', '.join(MODES)}, not {mode!r}.");
    }
    return mode;
}

"""Refuse to listen on `host` when it is not allowed in this mode: local
mode binds 127.0.0.1 only."""
def check_bind(host: str) {
    if app_mode() == LOCAL and host != LOOPBACK {
        raise ValueError(f"Local mode listens on {LOOPBACK} only, not {host}.");
    }
}

def user_manager -> UserManager {
    return Jac.get_user_manager(base_path=APP_DIR);
}

"""The guest's root id: the root Jac's own server runs anonymous calls on,
made the way it makes it. Read from the guest's user record each time, not
through `get_root_id`'s cache, so a graph emptied under it (as `jac test`
does between tests) gets a fresh guest."""
def guest_root_id -> str {
    um = user_manager();
    guest = um.get_user(Con.GUEST.value);
    if not guest {
        um.ensure_internal_user(Con.GUEST.value, "__no_password__");
        guest = um.get_user(Con.GUEST.value);
    }
    return str(guest["root_id"]);
}

"""The root id of user `caller`, made on first use: a Jac user with no
username and no password, so it cannot sign in at any Jac endpoint."""
def user_root_id(caller: str | None) -> str {
    if not caller {
        raise PermissionError("No caller: the call is refused.");
    }
    found = user_manager().ensure_user_root(caller);
    if not found {
        raise PermissionError(f"No root for caller {caller!r}: the call is refused.");
    }
    return str(found);
}

"""Run `work` on root `root_id`, in its own request context, and commit.
The lock is re-entrant only so that `start` can run the guest's set-up
inside it; calls still run one at a time.
On any error the call's writes are rolled back. A write conflict re-runs
`work`, up to `RERUNS` times; one still conflicting after that, and any
write Jac refuses, raise `CallFailed`. `name` (the walker or function) and
`caller` are for the log. Other errors are raised as they are. A call that
holds the lock longer than `SLOW_CALL_S` is logged with its name, caller and
duration, so a call that wedges the runner shows in the log."""
def in_context(root_id: str, work: Callable[[], object], name: str = "", caller: str = "") -> object {
    with runner_lock(name=name, caller=caller) {
        began = time.monotonic();
        try {
            return rerun_on_conflict(root_id, work, name, caller);
        } finally {
            held = time.monotonic() - began;
            if held > SLOW_CALL_S {
                LOG.warning("%s for caller %s held the runner's lock for %.1fs", name, caller, held);
            }
        }
    }
}

"""`in_context`'s tries: `attempt` until it commits, re-running on a write conflict."""
def rerun_on_conflict(root_id: str, work: Callable[[], object], name: str, caller: str) -> object {
    reruns = 0;
    while True {
        try {
            return attempt(root_id, work);
        } except PermissionError as refused {
            LOG.error("Jac refused a write in %s for caller %s: %s", name, caller, refused);
            raise CallFailed(error=internal_error()) from refused;
        } except Exception as e {
            if not is_write_conflict(e) {
                raise;
            }
            if reruns >= RERUNS {
                LOG.warning("%s for caller %s still conflicted after %d re-runs", name, caller, reruns);
                raise CallFailed(error=try_again()) from e;
            }
            reruns += 1;
            time.sleep(random.uniform(*RERUN_WAIT_S));
        }
    }
}

"""One try at `work` on root `root_id`: run it in a fresh request context and
commit, or roll it all back and raise.

The try is one unit of work, as Jac's own server makes it. A walker's spawn
commits by itself when the walker ends and swallows any error from that
commit; inside a unit a conflict there keeps every write pending, so the
runner's own commit meets the same conflict and raises it. Outside a unit
Jac would drop the conflicting write and the runner's commit would save the
rest."""
def attempt(root_id: str, work: Callable[[], object]) -> object {
    ctx = ExecutionContext(_parent=Jac.get_context());
    ctx.set_user_root(root_id);
    token = Jac.push_request_context(ctx);
    ctx.mem.unit_enter();
    try {
        done = work();
        Jac.commit();
        return done;
    } except Exception {
        ctx.mem.abort();
        raise;
    } finally {
        ctx.mem.unit_exit();
        Jac.reset_request_context(token);
    }
}

"""Register the guest root as Jac's shared root, and have the guest create
the Catalog and Format nodes, open to every user for reading. Runs before
the first call, and again only if the guest's root changes (`jac test`
starts each test on an empty graph) or the registration was cleared."""
def start {
    with runner_lock(name="start", caller=Con.GUEST.value) {
        guest = guest_root_id();
        # The shared root is also registered again when something cleared it (Jac's test
        # client does on close) while the guest stayed the same.
        if STARTED_FOR_GUEST == [guest] and Jac.shared_root_id() is not None {
            return;
        }
        Jac.set_shared_root_resolver(lambda () -> str | None { return guest; });
        in_context(
            guest, lambda () -> object { open_catalog(root); open_formats(root); return None; },
            name="start", caller=Con.GUEST.value
        );
        STARTED_FOR_GUEST.clear();
        STARTED_FOR_GUEST.append(guest);
    }
}

"""Spawn walker `w` as `caller` on that caller's own root, and return the
finished walker. No caller is a refusal, never a fall back to the guest.
A call the runner could not finish returns a copy of `w` whose one report
is the walker error (`try-again` or `internal-error`)."""
def run_walker(caller: str | None, w: WalkerArchetype) -> WalkerArchetype {
    done = call_function(caller, lambda () -> object { return spawn_on_root(w); }, name=type(w).__name__);
    if isinstance(done, WalkerError) {
        return failed_walker(w, done);
    }
    return stamp_ownership(done as WalkerArchetype, True);
}

"""Set `mine` on every deck view `w` reported: whether the caller owns the deck.
The runner is where both the deck's owner and the caller are known, so it is
the one place that says; no caller compares root ids itself."""
def stamp_ownership(w: WalkerArchetype, mine: bool) -> WalkerArchetype {
    for item in w.reports {
        if isinstance(item, DeckView) {
            item.mine = mine;
        }
    }
    return w;
}

"""A copy of `w` whose one report is the walker error `error`."""
def failed_walker(w: WalkerArchetype, error: WalkerError) -> WalkerArchetype {
    done = copy.deepcopy(w);
    done.reports = [error];
    return done;
}

"""Spawn the read-only walker `w` (one that acts on the deck `deck_id`) as the
deck's owner, on the owner's root, for `caller`: any signed-in user may read
any deck. The app has decided that read is allowed: only `perform`
(`deck_operations.jac`, whose table lists the read-only walkers) and
`copy_deck` call it, and the walker must change nothing. It gives the caller
no grant, edge or access of any kind. An id that names no deck runs as the caller, so it answers no-such-deck. No caller
is a refusal. Like `run_walker`, a call the runner could not finish returns a
copy of `w` whose one report is the walker error."""
def run_read(caller: str | None, deck_id: str, w: WalkerArchetype) -> WalkerArchetype {
    owner = call_function(caller, lambda () -> object { return deck_owner(deck_id); }, name="deck_owner");
    if isinstance(owner, WalkerError) {
        return failed_walker(w, owner);
    }
    if owner is None {
        return run_walker(caller, w);
    }
    try {
        done = in_context(
            owner as str, lambda () -> object { return spawn_on_root(w); }, name=type(w).__name__, caller=str(caller)
        ) as WalkerArchetype;
        # The deck's anchor spells its root with dashes, the user record without.
        mine = (owner as str).replace("-", "") == user_root_id(caller).replace("-", "");
        return stamp_ownership(done, mine);
    } except CallFailed as failed {
        return failed_walker(w, failed.error);
    }
}

"""Spawn the read-only walker `w` on the root of the user named by `handle`
(see `list_users`), for `caller`: any signed-in user may read any user's
collection. Like `run_read` it gives the caller no grant, edge or access of any
kind, and the walker must change nothing; only `perform` calls it, for the
`USER` entries of its table. Like `run_walker`, a call the runner could not
finish returns a copy of `w` whose one report is the walker error."""
def run_read_user(caller: str | None, handle: str, w: WalkerArchetype) -> WalkerArchetype {
    found = call_function(
        caller, lambda () -> object { return [r for r in user_root_ids() if user_handle(r) == handle]; }, name="user_root"
    );
    if isinstance(found, WalkerError) {
        return failed_walker(w, found);
    }
    if not (found as list[str]) {
        return failed_walker(w, WalkerError(code=NO_SUCH_USER, message="There is no such user."));
    }
    try {
        return in_context(
            (found as list[str])[0], lambda () -> object { return spawn_on_root(w); }, name=type(w).__name__, caller=str(caller)
        ) as WalkerArchetype;
    } except CallFailed as failed {
        return failed_walker(w, failed.error);
    }
}

"""Copy the deck `deck_id`, whoever owns it, into `caller`'s own decks, as a
snapshot: a read as the owner, then a create as the caller. Returns the
finished create walker, whose one report is the new deck's view, or the walker
that failed (an id that names no deck is no-such-deck) with its walker error."""
def copy_deck(caller: str | None, deck_id: str) -> WalkerArchetype {
    source = run_read(caller, deck_id, CopySource(deck_id=deck_id));
    snapshot = source.reports[0];
    if isinstance(snapshot, WalkerError) {
        return source;
    }
    return run_walker(caller, CopyDeck(snapshot=snapshot));
}

"""The root id of every user who has one, in no set order. The guest's is left out,
and so are Jac's own accounts (its `admin`): only the `user` role is a person."""
def user_root_ids -> list[str] {
    storage = user_manager()._identity_storage;
    guest = guest_root_id();
    found: list[str] = [];
    known: set[str] = set();
    offset = 0;
    while True {
        page = storage.list_all_users(limit=USER_PAGE, offset=offset);
        for user in page {
            rid = str(user.get("root_id") or "");
            if rid and rid != guest and user.get("role") == PERSON_ROLE and rid not in known {
                known.add(rid);
                found.append(rid);
            }
        }
        if len(page) < USER_PAGE {
            return found;
        }
        offset += USER_PAGE;
    }
}

"""Every deck of every other user (not `caller`'s own), by owner then deck
name. Each user's decks are read on that user's root, with their stored
display name. A call the runner could not finish returns its walker error."""
def list_other_decks(caller: str | None) -> list[DeckSummary] | WalkerError {
    try {
        start();
        mine = user_root_id(caller);
        others: list[DeckSummary] = [];
        for root_id in user_root_ids() {
            if root_id == mine {
                continue;
            }
            others += in_context(
                root_id, lambda () -> object { return deck_summaries(); }, name="list_other_decks", caller=str(caller)
            ) as list[DeckSummary];
        }
        return sorted(others, key=lambda (d: DeckSummary) { return (d.owner, d.name); });
    } except CallFailed as failed {
        return failed.error;
    }
}

"""The opaque handle of the user whose root is `root_id`: the root id without
its dashes, which is no email address and gives a caller nothing to act on."""
def user_handle(root_id: str) -> str {
    return root_id.replace("-", "");
}

"""Every other user (not `caller`), by display name then handle, each with the
display name stored on their own root ("Unknown user" when none is stored). A
call the runner could not finish returns its walker error."""
def list_users(caller: str | None) -> list[UserSummary] | WalkerError {
    try {
        start();
        mine = user_handle(user_root_id(caller));
        others: list[UserSummary] = [];
        for root_id in user_root_ids() {
            handle = user_handle(root_id);
            if handle == mine {
                continue;
            }
            name = in_context(
                root_id, lambda () -> object { return display_name(); }, name="list_users", caller=str(caller)
            ) as str;
            others.append(UserSummary(handle=handle, name=name));
        }
        return sorted(others, key=lambda (u: UserSummary) { return (u.name, u.handle); });
    } except CallFailed as failed {
        return failed.error;
    }
}

"""Call `f` (a page function, or other read of the graph) as `caller` on
that caller's own root, and return what it returns. A call the runner could
not finish returns its walker error instead. `name` names the call in the log."""
def call_function(caller: str | None, f: Callable[[], object], name: str = "") -> object {
    try {
        start();
        root_id = user_root_id(caller);
        return in_context(root_id, f, name=name or getattr(f, "__name__", "function"), caller=str(caller));
    } except CallFailed as failed {
        return failed.error;
    }
}

"""Spawn walker `w` as the guest, for the app's own work on the cards and
formats every user shares. Never reached from a request. A call the runner
could not finish returns a copy of `w` whose one report is the walker error;
work done at start (`refresh_cards`) raises on it, which fails the start."""
def run_as_guest(w: WalkerArchetype) -> WalkerArchetype {
    try {
        start();
        return in_context(
            guest_root_id(), lambda () -> object { return spawn_on_root(w); }, name=type(w).__name__, caller=Con.GUEST.value
        ) as WalkerArchetype;
    } except CallFailed as failed {
        return failed_walker(w, failed.error);
    }
}

"""Spawn a copy of `w` on the acting root (a sync walker, so never a coroutine).
Under `jac run` every `report` is also echoed to stdout; that stays out of the
process's output, which carries a deck's contents and, for stdio MCP, the protocol."""
def spawn_on_root(w: WalkerArchetype) -> WalkerArchetype {
    with redirect_stdout(io.StringIO()) {
        done = Jac.spawn(Jac.get_context().get_root(), copy.deepcopy(w)) as WalkerArchetype;
        stamp_collection(done.reports);
        return done;
    }
}

"""At start, bring the Card nodes up to date with the card catalogue, as the
guest, if it is a different build from the one they were last refreshed
against. Runs in batches of `batch` cards, each its own commit, and records
the version only after the last, so a refresh that fails part way runs again
at the next start. Names every oracle id with more than one Card node in a
warning, and logs the catalogue version it found either way (so a deploy's
logs show which build is serving). A failure raises `RuntimeError`, which
fails the start. Returns whether it ran."""
def refresh_cards(batch: int = REFRESH_BATCH) -> bool {
    try {
        return refresh_steps(batch);
    } except CallFailed as failed {
        raise RuntimeError(f"The card refresh could not finish: {failed.error.message}") from failed;
    }
}

"""The steps of `refresh_cards`, which raises `CallFailed` where a step meets it."""
def refresh_steps(batch: int) -> bool {
    start();
    version = catalogue_version();
    guest = guest_root_id();
    last_version = in_context(
        guest, lambda () -> object { return refreshed_version(root); }, name="refresh_cards", caller=Con.GUEST.value
    ) as str;
    if last_version == version {
        LOG.info("Card catalogue %s: the card nodes are already refreshed against it", version);
        return False;
    }
    offset = 0;
    while True {
        reports = run_as_guest(RefreshCards(offset=offset, size=batch)).reports;
        if isinstance(reports[0], WalkerError) {
            raise CallFailed(error=reports[0]);
        }
        offset += batch;
        if reports[1] as int < batch {
            break;
        }
    }
    duplicated = in_context(
        guest, lambda () -> object { record_refresh(root, version); return duplicate_oracle_ids(root); },
        name="refresh_cards", caller=Con.GUEST.value
    ) as list[str];
    for oid in duplicated {
        LOG.warning("More than one Card node for oracle id %s: the catalogue always uses the lowest id", oid);
    }
    LOG.info("Card catalogue %s: refreshed the card nodes (they were against %s)", version, last_version or "none");
    return True;
}
