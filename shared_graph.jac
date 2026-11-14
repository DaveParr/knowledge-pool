"""The app's shared graph, for processes other than the web app itself.

The web app's `:pub` walkers run on the guest root. The MCP server
(`mcp_server.jac`) and the seed script (`seed.jac`) spawn their walkers on
that same root, so all three see the same decks. The graph is in Postgres, so
any number of these processes may write it at once: a write that loses a race
is rolled back and run again (`run_walker`).
"""

import copy;
import os;
import sys;
import threading;
import time;
import from jaclang { JacRuntime as Jac }
import from jaclang.runtime.context { ExecutionContext }
import from jaclang.server.session { transient_db_error }
import from jaclang.runtime.constants { Constants as Con }

glob APP_DIR: str = os.path.dirname(os.path.abspath(__file__)),
     LOCK: threading.Lock = threading.Lock(),
     GUEST_ROOT: list[str] = [],
     # How many times `run_walker` runs a walker that keeps losing write races.
     MAX_ATTEMPTS: int = 8;

# A write Jac refuses fails the call and writes nothing, in every process.
# Jac reads JAC_STRICT_PERMISSIONS once, at import, so set the flag itself.
with entry {
    Jac.strict_permissions = True;
}

"""The root id of the app's shared (guest) graph, which the web app's `:pub` walkers use."""
def guest_root_id -> str {
    if not GUEST_ROOT {
        um = Jac.get_user_manager(base_path=APP_DIR);
        um.ensure_internal_user(Con.GUEST.value, "__no_password__");
        GUEST_ROOT.append(str(um.get_root_id(Con.GUEST.value)));
    }
    return GUEST_ROOT[0];
}

"""True when `e` is a lost write race that a fresh run of the walker can win."""
def write_conflict(e: Exception) -> bool {
    return transient_db_error(e) or type(e).__name__ == "WriteConflict";
}

"""Spawn a walker on the shared root, commit, and return the finished walker.

Same shape as one web request: a request context forked from the process
context. On any error the request's writes are rolled back; a lost write race
runs a fresh copy of the walker again, as Jac's own server does. Walkers must
do nothing outside the graph, so running one again is safe.
"""
def run_walker(w: any) -> any {
    with LOCK {
        attempt = 0;
        while True {
            attempt += 1;
            ctx = ExecutionContext(_parent=Jac.get_context());
            ctx.set_user_root(guest_root_id());
            token = Jac.push_request_context(ctx);
            try {
                done = Jac.spawn(ctx.get_root(), copy.deepcopy(w));
                Jac.commit();
                return done;
            } except Exception as e {
                ctx.mem.abort();
                if attempt >= MAX_ATTEMPTS or not write_conflict(e) {
                    raise;
                }
                sys.stderr.write(f"run_walker: {type(e).__name__}, running {type(w).__name__} again ({attempt})\n");  # jac:ignore[E1099]
                time.sleep(0.02 * attempt);
            } finally {
                Jac.reset_request_context(token);
            }
        }
    }
}
