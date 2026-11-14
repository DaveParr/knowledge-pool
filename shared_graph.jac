"""The app's shared graph, for processes other than the web app itself.

The web app's `:pub` walkers run on the guest root. The MCP server
(`mcp_server.jac`) and the seed script (`seed.jac`) spawn their walkers on
that same root, so all three see the same decks. The graph is in Postgres, so
any number of these processes may write it at once. A call that fails, for
example by losing a write race, is rolled back so the next call starts clean.
"""

import copy;
import os;
import threading;
import from jaclang { JacRuntime as Jac }
import from jaclang.runtime.context { ExecutionContext }
import from jaclang.runtime.constants { Constants as Con }

glob APP_DIR: str = os.path.dirname(os.path.abspath(__file__)),
     LOCK: threading.Lock = threading.Lock(),
     GUEST_ROOT: list[str] = [];

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

"""Spawn a walker on the shared root, commit, and return the finished walker.

Same shape as one web request: a request context forked from the process
context. On any error the request's writes are rolled back and the error is
raised, so a failed call (a lost write race, say) never leaves the process
holding an open transaction that blocks every later call.
"""
def run_walker(w: any) -> any {
    with LOCK {
        ctx = ExecutionContext(_parent=Jac.get_context());
        ctx.set_user_root(guest_root_id());
        token = Jac.push_request_context(ctx);
        try {
            done = Jac.spawn(ctx.get_root(), copy.deepcopy(w));
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
