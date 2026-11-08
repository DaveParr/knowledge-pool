"""MCP server for Claude Code and Claude Desktop (local stdio or HTTP).

The MCP SDK's MCPServer (FastMCP before mcp 2.0) runs in the same process as
the Jac graph. Deck and format tools each spawn a walker against the app's
shared root, the same root the web app's `:pub` walkers use. Card search,
lookup and name resolution go through the card catalogue module (`cards`).
No tool calls a model.

This process also serves the web app (UI and REST) on port 8000, because two
Jac processes writing the same saved graph overwrite each other's changes. So
stop `jac start` before connecting Claude; while Claude is connected, the app
is at http://localhost:8000 as usual.

    claude mcp add knowledge-pool -- uv run --directory <repo> jac run mcp_server.jac

Environment: KP_PORT (default 8000) for the web app, KP_WEB=0 to skip it.
KP_TRANSPORT=http switches the MCP endpoint itself from stdio to streamable
HTTP (KP_HTTP_HOST, default 127.0.0.1; KP_HTTP_PORT, default 8020), for
clients (e.g. a remote/custom connector) that need a URL instead of a local
command. That endpoint is plain HTTP: it has no TLS of its own, so putting it
behind something that terminates HTTPS (a tunnel like `cloudflared` or
`ngrok`, or a reverse proxy) is up to whoever needs a public https:// URL for
it — localhost is not reachable from a connector that calls in from outside
this machine.
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
import from mcp.server.apps { Apps }
import from mcp_types { CallToolResult, TextContent }
import from mcp.server.stdio { stdio_server }
import from mcp.server.streamable_http { TransportSecuritySettings }
import from jaclang { JacRuntime as Jac }
import from jaclang.runtimelib.context { ExecutionContext }
import from jaclang.jac0core.constant { Constants as Con }
import from cards { search_cards as catalog_search, find_card, resolve_names as catalog_resolve_names }
import from decks {
    Deck, DeckView, CreateDeck, ListDecks, GetDeck, SetDeckFormat, EditDeck
}
import from deck_io { DeckExport, DeckImport }
import from legality { GetFormatRules }
import from walker_errors { WalkerError }

glob APP_DIR: str = os.path.dirname(os.path.abspath(__file__)),
     LOCK: threading.Lock = threading.Lock(),
     GUEST_ROOT: list[str] = [],
     DECK_UI: str = "ui://knowledge-pool/deck-table.html";

"""Show a deck to the user as a table in the chat: cards by zone, totals and legality.
Clients that support MCP Apps (Claude Desktop and claude.ai) render it as an HTML table;
others get the same list as Markdown. Use deck_get when you only need the data."""
def deck_show(deck_id: str) -> CallToolResult {
    view = outcome(run_walker(GetDeck(deck_id=deck_id)));
    if "error" in view {
        return CallToolResult(content=[TextContent(text=view["error"])], is_error=True);
    }
    return CallToolResult(content=[TextContent(text=deck_markdown(view))], structured_content=view);
}

"""The deck as a Markdown table, for clients that do not render MCP Apps."""
def deck_markdown(view: dict) -> str {
    lines = [
        f"## {view['name']}",
        f"{view['format']}, {view['main_total']} main, {view['sideboard_total']} sideboard. "
        + ("Legal." if view["legal"] else "Not legal: " + "; ".join(v["message"] for v in view["violations"]))
    ];
    for (zone, title) in [("main", "Main deck"), ("sideboard", "Sideboard")] {
        rows = [c for c in view["cards"] if c["zone"] == zone];
        if rows {
            lines += ["", f"### {title}", "", "| # | Card | Cost | Type | Tags |", "|--:|---|---|---|---|"];
            lines += [
                f"| {c['count']} | {c['name']} | {c['mana_cost']} | {c['type_line']} | {', '.join(t for t in c['oracle_tags'])} |"
                for c in rows
            ];
        }
    }
    return "\n".join(lines);
}

"""MCP Apps: deck_show is bound to a self-contained HTML view (ui/deck_table.html)
that the host renders in a sandboxed iframe and fills from the tool result."""
def make_apps -> Apps {
    apps = Apps();
    apps.tool(resource_uri=DECK_UI)(deck_show);
    with open(os.path.join(APP_DIR, "ui", "deck_table.html"), encoding="utf-8") as f {
        apps.add_html_resource(DECK_UI, f.read(), title="Deck table", prefers_border=True);
    }
    return apps;
}

glob server: MCPServer = MCPServer(
    "knowledge-pool",
    instructions=(
        "Build and edit Magic: The Gathering decks in the user's local Knowledge Pool app. "
        + "Card data comes only from the MTGJSON catalogue: turn card names into oracle ids with "
        + "resolve_names (or search_cards) before adding them, and never add a card that was not "
        + "resolved. Give a short reason for every deck change. Finish with deck_validate. "
        + "When the user wants to see a deck, call deck_show."
    ),
    extensions=[make_apps()]
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

"""A finished walker's result as tool output: its first report as plain data,
or {"error": message, "code": code} when it reported a WalkerError. The
walker says why it failed, so no tool has to guess."""
def outcome(w: any) -> dict {
    first = w.reports[0];
    if isinstance(first, WalkerError) {
        return {"error": first.message, "code": first.code};
    }
    return plain(first) as dict;
}

"""Search card names, type lines and rules text. Every word must match, as a prefix."""
@server.tool()
def search_cards(query: str, limit: int = 20) -> list[dict] {
    return [plain(hit) for hit in catalog_search(query, limit)];
}

"""Full card details, by oracle id or exact card name, including format legalities."""
@server.tool()
def get_card(oracle_id_or_name: str) -> dict {
    card = find_card(oracle_id_or_name);
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
    return catalog_resolve_names(names);
}

"""Deck-construction rules for a format: standard, pioneer or modern."""
@server.tool()
def get_format_rules(format: str) -> dict {
    return outcome(run_walker(GetFormatRules(format=format)));
}

"""List the user's decks (id, name, format)."""
@server.tool()
def deck_list() -> list[dict] {
    decks = plain(run_walker(ListDecks()).reports[0]);
    return [{"id": d["id"], "name": d["name"], "format": d["format"]} for d in decks];
}

"""Create a deck, optionally with seed cards. Each card is
{"oracle_id": ..., "count": n, "zone": "main" | "sideboard" | "commander" | "companion" | "maybeboard", "reason": ...};
get oracle ids from resolve_names first. Returns the deck with its legality."""
@server.tool()
def deck_create(name: str, format: str = "standard", cards: list[dict] = []) -> dict {
    made = outcome(run_walker(CreateDeck(name=name, format=format)));
    if "error" in made {
        return made;
    }
    deck_id = str(made["id"]);
    if not cards {
        return deck_get(deck_id);
    }
    changes = [{**c, "reason": c.get("reason") or "seed card"} for c in cards];
    return deck_edit(deck_id, changes);
}

"""A deck: its cards, totals, legality and recent change history."""
@server.tool()
def deck_get(deck_id: str) -> dict {
    return outcome(run_walker(GetDeck(deck_id=deck_id)));
}

"""Change a deck. Each change is
{"oracle_id": ..., "count": n, "zone": "main" | "sideboard" | "commander" | "companion" | "maybeboard", "reason": "why"}
and sets that card's count in that zone (0 removes it). Every change needs a reason.
Pass "format" to change the deck's format. Changes with an unknown oracle id or no
reason are rejected and listed under "rejected"; the rest are applied."""
@server.tool()
def deck_edit(deck_id: str, changes: list[dict] = [], format: str = "") -> dict {
    if format {
        reformatted = outcome(run_walker(SetDeckFormat(deck_id=deck_id, format=format)));
        if "error" in reformatted {
            return reformatted;
        }
    }
    return outcome(run_walker(EditDeck(deck_id=deck_id, changes=changes)));
}

"""Check a deck against its format. Returns legal (true or false) and each violation."""
@server.tool()
def deck_validate(deck_id: str) -> dict {
    view = deck_get(deck_id);
    if "error" in view {
        return view;
    }
    return {
        "deck_id": deck_id,
        "format": view["format"],
        "legal": view["legal"],
        "violations": view["violations"]
    };
}

"""Mana analysis for a deck: land count, coloured pips (spell demand) and
coloured sources (lands and other cards that produce that colour), plus the
non-land mana curve (card count by mana value, 0-6 and 7+) and its average.
Main deck only - the sideboard is excluded. deck_get and deck_edit return the
same analysis with the whole deck; this tool returns only the analysis."""
@server.tool()
def deck_analyze(deck_id: str) -> dict {
    view = deck_get(deck_id);
    if "error" in view {
        return view;
    }
    return {"id": view["id"], "mana": view["mana"], "curve": view["curve"]};
}

"""Export a deck: mtgdeck1 (lossless), mtgjson (lossless, export only), or text/arena/moxfield (lossy)."""
@server.tool()
def deck_export(deck_id: str, format: str = "mtgdeck1") -> dict {
    return outcome(run_walker(DeckExport(deck_id=deck_id, format=format)));
}

"""Import a deck list, replacing the deck's current cards. Accepts mtgdeck1,
text, arena or moxfield. Lines that don't resolve to a known card are listed
under "unresolved" and never added."""
@server.tool()
def deck_import(deck_id: str, format: str, text: str) -> dict {
    return outcome(run_walker(DeckImport(deck_id=deck_id, format=format, text=text)));
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

"""Run MCP over streamable HTTP instead of stdio, for clients that need a URL.

The transport rejects any Host/Origin it doesn't recognize (DNS-rebinding
protection), so a host sitting in front of this (e.g. a tunnel) must be
listed in KP_HTTP_ALLOWED_HOSTS, a comma-separated list of hostnames
(with port, if any) such as "my-tunnel.trycloudflare.com".
"""
async def serve_http(host: str, port: int) {
    extra_hosts = [h.strip() for h in os.environ.get("KP_HTTP_ALLOWED_HOSTS", "").split(",") if h.strip()];
    hosts = [f"127.0.0.1:{port}", f"localhost:{port}"] + extra_hosts;
    origins = [f"https://{h}" for h in extra_hosts] + [f"http://{h}" for h in extra_hosts];
    security = TransportSecuritySettings(allowed_hosts=hosts, allowed_origins=origins);
    await server.run_streamable_http_async(host=host, port=port, transport_security=security);  # jac:ignore[E1053]
}

with entry:__main__ {
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

    if os.environ.get("KP_TRANSPORT", "stdio") == "http" {
        http_host = os.environ.get("KP_HTTP_HOST", "127.0.0.1");
        http_port = int(os.environ.get("KP_HTTP_PORT", "8020"));
        anyio.run(serve_http, http_host, http_port);  # jac:ignore[E1053]
    } else {
        # stdout carries the MCP protocol, so keep a handle to it and send all
        # other output (walker reports, server logs) to stderr.
        mcp_out = io.TextIOWrapper(os.fdopen(os.dup(1), "wb"), encoding="utf-8", line_buffering=True);
        os.dup2(2, 1);
        sys.stdout = sys.stderr;
        anyio.run(serve_stdio, mcp_out);  # jac:ignore[E1053]
    }
}
