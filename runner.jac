"""The runner: the one way the app runs a walker or a page function, and who it
runs as.

Every deck action runs as a caller, on that caller's own root. A caller is a
user id; the root comes from `ensure_user_root(<id>)` on every call, so a user
needs no Jac username or password and cannot sign in at any Jac endpoint. The
caller is read in one place, `request_caller`: in local mode it is always the
local user, and in hosted mode it will come from the front door's verified
token or session. No tool or walker takes a user argument, and no caller is a
refusal, never the guest.

The guest is the app's own identity. Its root is registered as Jac's shared
root (`root.shared` inside a walker), and holds what every user shares: the
`Catalog` with its cards, and the `Format` nodes. `start` has the guest create
those before any user call. `run_as_guest` runs the app's own work as the
guest; no request reaches it.

Walkers run one at a time across all users (one process-wide lock). The graph
is in Postgres, so other processes may write it at once. A call that fails is
rolled back, so the next call starts clean.
"""

import copy;
import logging;
import os;
import threading;
import from uuid { UUID }
import from jaclang { JacRuntime as Jac }
import from jaclang.runtime.context { ExecutionContext }
import from jaclang.runtime.constants { Constants as Con }
import from jaclang.runtime.constructs { WalkerArchetype }
import from jaclang.server.identity.user_manager { UserManager }
import from cards { catalog_node }
import from legality { format_nodes }

glob APP_DIR: str = os.path.dirname(os.path.abspath(__file__)),
     LOCK: threading.Lock = threading.Lock(),
     # The one user every call runs as in local mode. It owns the decks made there.
     LOCAL_USER: str = "local-user",
     # The mode setting: "local" on a developer's machine, "hosted" in the image.
     MODES: list[str] = ["local", "hosted"],
     LOOPBACK: str = "127.0.0.1";

# A write Jac refuses fails the call and writes nothing, in every process.
# Jac reads JAC_STRICT_PERMISSIONS once, at import, so set the flag itself.
with entry {
    Jac.strict_permissions = True;
}

"""The mode this process runs in, from KP_MODE ("local" when unset). Any other
value is an error, so a typo never runs as the wrong mode."""
def mode -> str {
    value = os.environ.get("KP_MODE", "local");
    if value not in MODES {
        raise ValueError(f"KP_MODE must be one of {', '.join(MODES)}, not {value!r}.");
    }
    return value;
}

"""Refuse to listen on `host` when this mode forbids it: local mode has no
sign-in, so it serves on 127.0.0.1 only."""
def check_bind(host: str) {
    if mode() == "local" and host != LOOPBACK {
        raise ValueError(f"Local mode has no sign-in, so it serves on {LOOPBACK} only, not {host}.");
    }
}

"""Who the current request is from: the local user in local mode. Hosted mode
has no caller until the front door verifies one, so every call is refused."""
def request_caller -> str | None {
    if mode() == "local" {
        return LOCAL_USER;
    }
    return None;
}

"""Jac's users for this process's graph (its base path, else the app's directory)."""
def users -> UserManager {
    return Jac.get_user_manager(base_path=Jac.get_base_path_dir() or APP_DIR);
}

"""The root id of the guest, the app's own identity, whose root is Jac's
shared root: the same guest Jac's own server makes, so both processes share
one card catalogue. Jac caches it once `start` registers it."""
def guest_root_id -> str {
    um = users();
    um.ensure_internal_user(Con.GUEST.value, "__no_password__");
    found = str(um.get_root_id(Con.GUEST.value));
    if Jac.get_context().mem.get(UUID(found)) is None {
        # As Jac's own server does: a guest root missing from the graph is minted afresh.
        logging.getLogger(__name__).warning(f"Guest root {found} is missing from the graph; minting a fresh one.");
        found = str(um.reset_root(Con.GUEST.value));
    }
    return found;
}

"""The root id of user `caller`, made on first use. Refuses a missing caller,
and refuses the guest: no request runs as the app's own identity."""
def user_root_id(caller: str | None) -> str {
    if not caller {
        raise PermissionError("Refused: this call has no caller.");
    }
    found = users().ensure_user_root(caller);
    if found is None or UUID(str(found)) == Jac.shared_root_id() {
        raise PermissionError(f"Refused: {caller!r} is not a user.");
    }
    return str(found);
}

"""Register the guest's root as Jac's shared root, then have the guest create
the `Catalog` and the `Format` nodes, opened at READ so every user can look
cards and formats up but not change them. Run once at start, before any user
call; safe to run again."""
def start {
    Jac.set_shared_root_resolver(guest_root_id);
    call_as_guest(open_shared_nodes);
}

"""Create the guest's shared nodes if missing and open them at READ. Runs as the guest."""
def open_shared_nodes {
    grant(catalog_node(root), level=AccessLevel.READ);
    for f in format_nodes(root) {
        grant(f, level=AccessLevel.READ);
    }
}

"""Run `w` as `caller` on the caller's own root and return the finished walker."""
def run_as(caller: str | None, w: WalkerArchetype) -> WalkerArchetype {
    return call_as(caller, lambda -> WalkerArchetype { return spawn_here(w); }) as WalkerArchetype;
}

"""Run page function `fn` as `caller` on the caller's own root and return its result."""
def call_as(caller: str | None, fn: Callable[[], object]) -> object {
    with LOCK {
        home = user_root_id(caller);
        return on_root(home, fn);
    }
}

"""Run `w` for the current request: as `request_caller()`, the one place a request's caller is read."""
def run_walker(w: WalkerArchetype) -> WalkerArchetype {
    return run_as(request_caller(), w);
}

"""Run page function `fn` for the current request, as `request_caller()`."""
def call_function(fn: Callable[[], object]) -> object {
    return call_as(request_caller(), fn);
}

"""Run `w` as the guest, for the app's own work. No request reaches this."""
def run_as_guest(w: WalkerArchetype) -> WalkerArchetype {
    return call_as_guest(lambda -> WalkerArchetype { return spawn_here(w); }) as WalkerArchetype;
}

"""Run function `fn` as the guest, for the app's own work. No request reaches this."""
def call_as_guest(fn: Callable[[], object]) -> object {
    with LOCK {
        return on_root(guest_root_id(), fn);
    }
}

"""Spawn a copy of `w` on the current context's root (so a caller's walker is never shared between calls)."""
def spawn_here(w: WalkerArchetype) -> WalkerArchetype {
    return Jac.spawn(Jac.get_context().get_root(), copy.deepcopy(w)) as WalkerArchetype;  # a sync walker, so never a coroutine
}

"""Run `work` in a request context on root `root_id`, then commit.

Same shape as one web request: a request context forked from the process
context. On any error the request's writes are rolled back and the error is
raised, so a failed call never leaves the process holding an open
transaction that blocks every later call. Callers hold LOCK."""
def on_root(root_id: str, work: Callable[[], object]) -> object {
    ctx = ExecutionContext(_parent=Jac.get_context());
    ctx.set_user_root(root_id);
    token = Jac.push_request_context(ctx);
    try {
        done = work();
        Jac.commit();
        return done;
    } except Exception {
        ctx.mem.abort();
        raise;
    } finally {
        Jac.reset_request_context(token);
    }
}
