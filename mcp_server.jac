"""MCP server for Claude Code and Claude Desktop (local stdio).

The MCP SDK's MCPServer (FastMCP before mcp 2.0) runs in the same process as
the Jac graph. Deck and format tools each spawn a walker against the app's
shared root, the same root the web app's `:pub` walkers use. Card search and
lookup read the SQLite catalogue directly, as in the design. No tool calls a
model.

This process also serves the web app (UI and REST) on port 8000, because two
Jac processes writing the same saved graph overwrite each other's changes. So
stop `jac start` before connecting Claude; while Claude is connected, the app
is at http://localhost:8000 as usual.

    claude mcp add knowledge-pool -- uv run --directory <repo> jac run mcp_server.jac

Environment: KP_PORT (default 8000) for the web app, KP_WEB=0 to skip it.
"""

import io;
import os;
import socket;
import sys;
import threading;
import anyio;
import from dataclasses { asdict, is_dataclass }
import from datetime { datetime, timezone }
import from mcp.server.mcpserver { MCPServer }
import from mcp.server.stdio { stdio_server }
import from jaclang { JacRuntime as Jac }
import from jaclang.runtimelib.context { ExecutionContext }
import from jaclang.jac0core.constant { Constants as Con }
import from catalog { store }
import from decks {
    Deck, DeckView, CreateDeck, ListDecks, GetDeck, SetDeckFormat, EditDeck
}
import from legality { FORMAT_LABELS, GetFormatRules }

glob APP_DIR: str = os.path.dirname(os.path.abspath(__file__)),
     LOCK: threading.Lock = threading.Lock(),
     GUEST_ROOT: list[str] = [];

glob server: MCPServer = MCPServer(
    "knowledge-pool",
    instructions=(
        "Build and edit Magic: The Gathering decks in the user's local Knowledge Pool app. "
        + "Card data comes only from the MTGJSON catalogue: turn card names into oracle ids with "
        + "resolve_names (or search_cards) before adding them, and never add a card that was not "
        + "resolved. Give a short reason for every deck change. Finish with deck_validate."
    )
);

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

"""Plain JSON-ready data from walker reports (objs and nodes become dicts)."""
def plain(value: any) -> any {
    if is_dataclass(value) and not isinstance(value, type) {
        out = asdict(value);  # jac:ignore[E1054]
        if isinstance(value, Deck) {
            out["id"] = jid(value);
        }
        return out;
    }
    if isinstance(value, list) {
        return [plain(v) for v in value];
    }
    return value;
}

def first_report(w: any) -> any {
    return plain(w.reports[0]) if w.reports else None;
}

def deck_or_error(w: any, deck_id: str) -> dict {
    view = first_report(w);
    if view is None {
        return {"error": f"No deck with id {deck_id}."};
    }
    return view as dict;
}

"""Search card names, type lines and rules text. Every word must match, as a prefix."""
@server.tool()
def search_cards(query: str, limit: int = 20) -> list[dict] {
    return [
        {
            "oracle_id": c["oracle_id"],
            "name": c["name"],
            "mana_cost": c["mana_cost"],
            "type_line": c["type_line"],
            "text": c["text"]
        }
        for c in store.search(query, limit)
    ];
}

"""Full card details, by oracle id or exact card name, including format legalities."""
@server.tool()
def get_card(oracle_id_or_name: str) -> dict {
    card = store.get_card(oracle_id_or_name) or store.find_by_name(oracle_id_or_name);
    if card is None {
        return {"error": f"No card matches {oracle_id_or_name}. Try resolve_names or search_cards."};
    }
    return card;
}

"""Match card names to oracle ids. Returns `exact` matches, `fuzzy` matches with
candidates to choose from, and `unknown` names. Only exact matches (or a candidate
the user confirms) should go into a deck."""
@server.tool()
def resolve_names(names: list[str]) -> dict {
    return store.resolve_names(names);
}

"""Deck-construction rules for a format: standard, pioneer or modern."""
@server.tool()
def get_format_rules(format: str) -> dict {
    rules = first_report(run_walker(GetFormatRules(format=format)));
    if rules is None {
        return {"error": f"Unknown format {format}. Use one of: {', '.join(FORMAT_LABELS)}."};
    }
    return rules as dict;
}

"""List the user's decks (id, name, format)."""
@server.tool()
def deck_list() -> list[dict] {
    decks = first_report(run_walker(ListDecks())) or [];
    return [{"id": d["id"], "name": d["name"], "format": d["format"]} for d in decks];
}

"""Create a deck, optionally with seed cards. Each card is
{"oracle_id": ..., "count": n, "zone": "main" | "sideboard", "reason": ...};
get oracle ids from resolve_names first. Returns the deck with its legality."""
@server.tool()
def deck_create(name: str, format: str = "standard", cards: list[dict] = []) -> dict {
    made = run_walker(CreateDeck(name=name, format=format));
    if not made.reports {
        return {"error": f"Could not create the deck. The name must not be blank and the format must be one of: {', '.join(FORMAT_LABELS)}."};
    }
    deck_id = jid(made.reports[0]);
    if not cards {
        return deck_or_error(run_walker(GetDeck(deck_id=deck_id)), deck_id);
    }
    changes = [{**c, "reason": c.get("reason") or "seed card"} for c in cards];
    return deck_edit(deck_id, changes);
}

"""A deck: its cards, totals, legality and recent change history."""
@server.tool()
def deck_get(deck_id: str) -> dict {
    return deck_or_error(run_walker(GetDeck(deck_id=deck_id)), deck_id);
}

"""Change a deck. Each change is
{"oracle_id": ..., "count": n, "zone": "main" | "sideboard", "reason": "why"}
and sets that card's count in that zone (0 removes it). Every change needs a reason.
Pass "format" to change the deck's format. Changes with an unknown oracle id or no
reason are rejected and listed under "rejected"; the rest are applied."""
@server.tool()
def deck_edit(deck_id: str, changes: list[dict] = [], format: str = "") -> dict {
    if format {
        if not run_walker(SetDeckFormat(deck_id=deck_id, format=format)).reports {
            return {"error": f"No deck with id {deck_id}, or unknown format {format}."};
        }
    }
    done = run_walker(EditDeck(deck_id=deck_id, changes=changes));
    return deck_or_error(done, deck_id);
}

"""Check a deck against its format. Returns legal (true or false) and each violation."""
@server.tool()
def deck_validate(deck_id: str) -> dict {
    view = first_report(run_walker(GetDeck(deck_id=deck_id)));
    if view is None {
        return {"error": f"No deck with id {deck_id}."};
    }
    return {
        "deck_id": deck_id,
        "format": view["format"],
        "legal": view["legal"],
        "violations": view["violations"]
    };
}

"""True when something already listens on this local port."""
def port_in_use(port: int) -> bool {
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s {
        s.settimeout(0.5);
        return s.connect_ex(("127.0.0.1", port)) == 0;
    }
}

"""Serve the web app (UI and REST) from this process, on a background thread."""
def start_web(port: int) {
    Jac.jac_import(target="main", base_path=APP_DIR, lng="jac");
    ServerClass = Jac.get_api_server_class();
    web = ServerClass(module_name="main", port=port, base_path=APP_DIR);
    t = threading.Thread(target=web.start, kwargs={"dev": False, "no_client": False}, daemon=True);
    t.start();
}

"""Run MCP over the real stdout; everything else this process prints goes to stderr."""
async def serve_stdio(mcp_out: io.TextIOWrapper) {
    async with stdio_server(stdout=anyio.wrap_file(mcp_out)) as (read_stream, write_stream) {  # jac:ignore[E1052]
        low = server._lowlevel_server;
        await low.run(read_stream, write_stream, low.create_initialization_options());  # jac:ignore[E1053]
    }
}

with entry:__main__ {
    # stdout carries the MCP protocol, so keep a handle to it and send all other
    # output (walker reports, server logs) to stderr.
    mcp_out = io.TextIOWrapper(os.fdopen(os.dup(1), "wb"), encoding="utf-8", line_buffering=True);
    os.dup2(2, 1);
    sys.stdout = sys.stderr;

    os.chdir(APP_DIR);
    if os.environ.get("KP_WEB", "1") != "0" {
        port = int(os.environ.get("KP_PORT", "8000"));
        if port_in_use(port) {
            sys.stderr.write(  # jac:ignore[E1099]
                f"Port {port} is in use. If `jac start` is running, stop it: this MCP server serves the app itself, "
                + "and two processes writing one graph overwrite each other's decks. Or set KP_PORT.\n"
            );
            exit(1);
        }
        start_web(port);
    }
    anyio.run(serve_stdio, mcp_out);  # jac:ignore[E1053]
}
