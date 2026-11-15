"""The runner: the one way the app's processes run deck work on the graph.

Every deck action runs as a caller (a user id) on that caller's own root,
from `ensure_user_root(<id>)`. `run_walker` and `call_function` are the
caller's entries; every MCP tool goes through them. `run_as_guest` is the
second entry, for the app's own work on what every user shares (the cards
and the formats). Nothing a request reaches calls it.

The guest root is registered as Jac's shared root (`root.shared`), so the
card catalogue and the formats are looked up there, never under the
caller's root. Before the first call, the guest creates the `Catalog` and
`Format` nodes and opens them to every user for reading.

One lock runs walkers one at a time across all users. A call that fails is
rolled back, so the next call starts clean.

The app runs in one of two modes, set by `KP_MODE`: `local` (the default),
on a developer's machine, where every call runs as the fixed local user and
nothing binds anything but 127.0.0.1; or `hosted`, where the caller comes
from the front door's sign-in.
"""

import copy;
import os;
import threading;
import from jaclang { JacRuntime as Jac }
import from jaclang.runtime.context { ExecutionContext }
import from jaclang.runtime.constants { Constants as Con }
import from jaclang.runtime.constructs { WalkerArchetype }
import from jaclang.server.identity.user_manager { UserManager }
import from cards { open_catalog }
import from legality { open_formats }

glob APP_DIR: str = os.path.dirname(os.path.abspath(__file__)),
     LOCK: threading.RLock = threading.RLock(),
     LOCAL_USER: str = "local-user",
     LOOPBACK: str = "127.0.0.1",
     LOCAL: str = "local",
     HOSTED: str = "hosted",
     MODES: list[str] = [LOCAL, HOSTED],
     STARTED_FOR_GUEST: list[str] = [];

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

"""Who is asking, for a request that reaches this process: the local user
in local mode. Hosted mode has no caller until the front door's sign-in
names one, so every call is refused."""
def request_caller -> str | None {
    return LOCAL_USER if app_mode() == LOCAL else None;
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
On any error the call's writes are rolled back and the error is raised."""
def in_context(root_id: str, work: Callable[[], object]) -> object {
    with LOCK {
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
}

"""Register the guest root as Jac's shared root, and have the guest create
the Catalog and Format nodes, open to every user for reading. Runs before
the first call, and again only if the guest's root changes (`jac test`
starts each test on an empty graph)."""
def start {
    with LOCK {
        guest = guest_root_id();
        if STARTED_FOR_GUEST == [guest] {
            return;
        }
        Jac.set_shared_root_resolver(lambda () -> str | None { return guest; });
        in_context(guest, lambda () -> object { open_catalog(root); open_formats(root); return None; });
        STARTED_FOR_GUEST.clear();
        STARTED_FOR_GUEST.append(guest);
    }
}

"""Spawn walker `w` as `caller` on that caller's own root, and return the
finished walker. No caller is a refusal, never a fall back to the guest."""
def run_walker(caller: str | None, w: WalkerArchetype) -> WalkerArchetype {
    return call_function(caller, lambda () -> object { return spawn_on_root(w); }) as WalkerArchetype;
}

"""Call `f` (a page function, or other read of the graph) as `caller` on
that caller's own root, and return what it returns."""
def call_function(caller: str | None, f: Callable[[], object]) -> object {
    start();
    return in_context(user_root_id(caller), f);
}

"""Spawn walker `w` as the guest, for the app's own work on the cards and
formats every user shares. Never reached from a request."""
def run_as_guest(w: WalkerArchetype) -> WalkerArchetype {
    start();
    return in_context(guest_root_id(), lambda () -> object { return spawn_on_root(w); }) as WalkerArchetype;
}

"""Spawn a copy of `w` on the acting root (a sync walker, so never a coroutine)."""
def spawn_on_root(w: WalkerArchetype) -> WalkerArchetype {
    return Jac.spawn(Jac.get_context().get_root(), copy.deepcopy(w)) as WalkerArchetype;
}
