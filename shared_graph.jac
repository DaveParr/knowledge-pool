"""The app's shared graph, for processes other than the web app itself.

The web app's `:pub` walkers run on the guest root. The MCP server
(`mcp_server.jac`) and the seed script (`seed.jac`) spawn their walkers on
that same root, so all three see the same decks. Only one process may write
the saved graph at a time (two overwrite each other's changes): take
`acquire_graph_lock` before writing (the port check only catches a web app).
"""

import fcntl;
import os;
import socket;
import sys;
import threading;
import from jaclang { JacRuntime as Jac }
import from jaclang.runtimelib.context { ExecutionContext }
import from jaclang.jac0core.constant { Constants as Con }

glob APP_DIR: str = os.path.dirname(os.path.abspath(__file__)),
     LOCK: threading.Lock = threading.Lock(),
     GUEST_ROOT: list[str] = [],
     LOCK_FILES: list[any] = [];

"""The root id of the app's shared (guest) graph, which the web app's `:pub` walkers use."""
def guest_root_id -> str {
    if not GUEST_ROOT {
        um = Jac.get_user_manager(base_path=APP_DIR);
        if not um.user_exists(Con.GUEST.value) {
            um.create_user(Con.GUEST.value, "__no_password__");
        }
        GUEST_ROOT.append(str(um.get_root_id(Con.GUEST.value)));
    }
    return GUEST_ROOT[0];
}

"""Spawn a walker on the shared root, commit, and return the finished walker.

Same shape as one web request: a request context forked from the process
context, so both share one in-memory graph and one database connection.
"""
def run_walker(w: any) -> any {
    with LOCK {
        ctx = ExecutionContext(_parent=Jac.get_context());
        ctx.set_user_root(guest_root_id());
        token = Jac.push_request_context(ctx);
        try {
            done = Jac.spawn(ctx.get_root(), w);  # jac:ignore[E1053]
            Jac.commit();
            return done;
        } finally {
            Jac.reset_request_context(token);
        }
    }
}

"""True when something already listens on this local port."""
def port_in_use(port: int) -> bool {
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s {
        s.settimeout(0.5);
        return s.connect_ex(("127.0.0.1", port)) == 0;
    }
}

"""The directory that holds the saved graph: `<JAC_DATA_PATH or the app dir>/.jac/data`, as jaclang resolves it."""
def graph_dir -> str {
    return os.path.join(os.environ.get("JAC_DATA_PATH") or APP_DIR, ".jac", "data");
}

"""Take the exclusive writer lock on the saved graph, for the life of this process.

Exits 1 with a message when another process (MCP server, `jac script up`, seed)
holds it. The lock is an flock, so it goes when the process does, even on a crash.
"""
def acquire_graph_lock(owner: str) -> None {
    if LOCK_FILES {
        return;
    }
    gdir = graph_dir();
    os.makedirs(gdir, exist_ok=True);
    handle = open(os.path.join(gdir, "writer.lock"), "a+");
    try {
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB);
    } except OSError {
        handle.seek(0);
        holder = handle.read().strip() or "unknown";
        handle.close();
        sys.stderr.write(  # jac:ignore[E1099]
            f"The graph in {gdir} is in use by another knowledge-pool process ({holder}): "
            + "an MCP server, `jac script up`, or the seed script. Stop it first "
            + "(`jac script down` for a dev server): two processes writing one graph overwrite each other's decks.\n"
        );
        exit(1);
    }
    handle.seek(0);
    handle.truncate();
    handle.write(f"pid {os.getpid()}, {owner}");
    handle.flush();
    LOCK_FILES.append(handle);
}
