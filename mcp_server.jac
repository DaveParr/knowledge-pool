"""MCP server for Claude Code and Claude Desktop (local stdio or HTTP).

The MCP SDK's MCPServer (FastMCP before mcp 2.0) runs in the same process as
the Jac graph. Every tool goes through the runner (`graph_runner.jac`) as whoever
is asking: in local mode, the local user, so `deck_list` lists the local
user's decks. Deck and format tools each spawn a walker; card search,
lookup and name resolution go through the card catalogue module (`cards`).
No tool calls a model. In hosted mode the caller is the `sub` of the
WorkOS AuthKit token the gatekeeper (`gatekeeper.jac`) verified (`hosted_auth.jac`), and the
server refuses to start without its settings.

Over HTTP this process is also the front door (`front_door.jac`): the one
listener, which answers `/mcp`, runs the web page's deck calls through the
runner as the same caller, and hands the page out from Jac's server, its
child on 127.0.0.1. `jac x up` runs it for this worktree.

    claude mcp add knowledge-pool -- jac run --no-serve <repo>/mcp_server.jac

KP_TRANSPORT=http switches the MCP endpoint from stdio to streamable HTTP
(KP_HTTP_HOST, default 127.0.0.1; KP_HTTP_PORT, default 8020), for clients
(e.g. a remote/custom connector) that need a URL instead of a local command.
That endpoint is plain HTTP: it has no TLS of its own, so putting it behind
something that terminates HTTPS (a tunnel like `cloudflared` or `ngrok`, or a
reverse proxy) is up to whoever needs a public https:// URL for it — localhost
is not reachable from a connector that calls in from outside this machine.

The tools are plain functions in `mcp_tools.jac` and the text they build is in
`mcp_builders.jac`; this module only wires them to the transport: it builds the
MCP server, binds the view tools to their MCP Apps views, and runs it.
"""

import io;
import os;
import sys;
import anyio;
import httpx2;
import uvicorn;
import from mcp.server.mcpserver { MCPServer }
import from mcp.server.apps { Apps, ResourcePermissions }
import from mcp.server.stdio { stdio_server }
import from mcp.server.streamable_http { TransportSecuritySettings }
import from mcp_tools { adapted, deck_show, deck_analyze, card_search, deck_export, search_cards, get_card, resolve_names, get_format_rules, deck_list, deck_browse, deck_copy, deck_create, deck_get, deck_edit, deck_validate, deck_import }
import from ui_pages { view_page }
import from front_door { FrontDoorConfig, front_door_app }
import from gatekeeper { GatekeeperConfig }
import from upstream_child { start_upstream, stop_upstream, stop_child_on_sigterm, exit_when_upstream_dies, expect_upstream_to_stop }
import from urllib.parse { urlparse }
import from log_setup { use_json_logs }
import from browser_session { WorkOSSessions }
import from hosted_auth { AuthKitVerifier, HostedSettings, HostedSettingsMissing, hosted_settings, jwks_key_finder }
import from cards { check_catalogue }
import from graph_runner { APP_DIR, HOSTED, app_mode, check_bind, start, refresh_cards }

glob DECK_UI: str = "ui://knowledge-pool/deck-table.html",
     MANA_UI: str = "ui://knowledge-pool/mana-analysis.html",
     SEARCH_UI: str = "ui://knowledge-pool/card-search.html",
     EXPORT_UI: str = "ui://knowledge-pool/deck-export.html";

"""MCP Apps: deck_show, deck_analyze, card_search and deck_export are each bound
to a self-contained HTML view (ui/deck_table.html, ui/mana_analysis.html,
ui/card_search.html, ui/deck_export.html) that the host renders in a sandboxed
iframe and fills from the tool result. The search and export views also call
their tools (and deck_edit) back through the host."""
def make_apps -> Apps {
    apps = Apps();
    apps.tool(resource_uri=DECK_UI)(adapted(deck_show));
    apps.tool(resource_uri=MANA_UI)(adapted(deck_analyze));
    apps.add_html_resource(DECK_UI, view_page("deck_table.html"), title="Deck table", prefers_border=True);
    apps.add_html_resource(MANA_UI, view_page("mana_analysis.html"), title="Mana analysis", prefers_border=True);
    apps.tool(resource_uri=SEARCH_UI)(adapted(card_search));
    apps.add_html_resource(SEARCH_UI, view_page("card_search.html"), title="Card search", prefers_border=True);
    apps.tool(resource_uri=EXPORT_UI)(adapted(deck_export));
    apps.add_html_resource(
        EXPORT_UI, view_page("deck_export.html"), title="Deck export", prefers_border=True,
        # Ask for the clipboard so Copy works; the view selects the text when the host says no.
        permissions=ResourcePermissions(clipboard_write={})
    );
    return apps;
}

glob server: MCPServer[object] = MCPServer(
    "knowledge-pool",
    instructions=(
        "Build and edit Magic: The Gathering decks in the user's Knowledge Pool app. "
        + "Card data comes only from the MTGJSON catalogue: turn card names into oracle ids with "
        + "resolve_names (or search_cards) before adding them, and never add a card that was not "
        + "resolved. Give a short reason for every deck change. Finish with deck_validate. "
        + "When the user wants to see a deck, call deck_show; for its mana curve and colours, call deck_analyze. "
        + "When the user wants to find cards to add to a deck, call card_search with that deck's id: it shows "
        + "how many copies the deck already holds, and lets the user add hits themselves; changes they make "
        + "there are reported back to you. To export a deck, call deck_export. "
        + "Every user's decks are visible to every user: deck_list shows only the user's own, deck_browse "
        + "shows other users', and deck_copy makes one the user's own to change."
    ),
    extensions=[make_apps()]
);

"""Register the tools with no view; deck_show, deck_analyze, card_search and
deck_export are bound to their views in `make_apps`."""
def register_tools {
    for tool in [
        search_cards, get_card, resolve_names, get_format_rules, deck_list, deck_browse, deck_copy,
        deck_create, deck_get, deck_edit, deck_validate, deck_import
    ] {
        server.tool()(adapted(tool));
    }
}

with entry {
    register_tools();
}

"""Run MCP over the real stdout; everything else this process prints goes to stderr."""
async def serve_stdio(mcp_out: io.TextIOWrapper[io.BufferedWriter]) {
    # The checker cannot type `as (a, b)` destructuring yet (W1051, W2001).
    async with stdio_server(stdout=anyio.wrap_file(mcp_out)) as (read_stream, write_stream) {  # jac:ignore[E1052,W1051]
        low = server._lowlevel_server;
        await low.run(read_stream, write_stream, low.create_initialization_options());  # jac:ignore[E1053,W1051,W2001]
    }
}

"""Run the front door over HTTP instead of MCP over stdio, for clients that need a URL.

The one listener answers `/mcp` for MCP, the web page's deck calls and the
page itself (`front_door.jac`); `upstream` is Jac's server, the page's child.

The transport rejects any Host/Origin it doesn't recognize (DNS-rebinding
protection), so a host sitting in front of this (e.g. a tunnel) must be
listed in KP_HTTP_ALLOWED_HOSTS, a comma-separated list of hostnames
(with port, if any) such as "my-tunnel.trycloudflare.com".
"""
async def serve_http(host: str, port: int, upstream: str, hosted: HostedSettings | None = None) {
    extra_hosts = [h.strip() for h in os.environ.get("KP_HTTP_ALLOWED_HOSTS", "").split(",") if h.strip()];
    auth: AuthKitVerifier | None = None;
    sessions: WorkOSSessions | None = None;
    public_origin = "";
    if hosted is not None {
        # The public address is a host this server answers to, and the one origin its page's calls carry.
        extra_hosts.append(urlparse(hosted.audience).netloc);
        auth = AuthKitVerifier(issuer=hosted.issuer, audience=hosted.audience, key_for=jwks_key_finder(hosted.issuer));
        sessions = WorkOSSessions(client_id=hosted.client_id, api_key=hosted.api_key, cookie_password=hosted.cookie_password);
        public_origin = hosted.public_origin();
    }
    hosts = [f"127.0.0.1:{port}", f"localhost:{port}"] + extra_hosts;
    origins = [f"https://{h}" for h in extra_hosts] + [f"http://{h}" for h in extra_hosts];
    security = TransportSecuritySettings(allowed_hosts=hosts, allowed_origins=origins);
    mcp_app = server.streamable_http_app(host=host, transport_security=security);
    own_origins = [f"http://127.0.0.1:{port}", f"http://localhost:{port}"] + origins;
    gate = GatekeeperConfig(origins=own_origins, auth=auth, sessions=sessions, public_origin=public_origin);
    config = FrontDoorConfig(upstream=upstream, gate=gate, client=httpx2.AsyncClient());
    listener = uvicorn.Server(uvicorn.Config(front_door_app(mcp_app, config), host=host, port=port, log_level="info", log_config=(None if hosted is not None else uvicorn.config.LOGGING_CONFIG)));
    await listener.serve();
}

with entry:__main__ {
    os.chdir(APP_DIR);
    # Fail before MCP takes stdout: the message goes to stderr.
    check_catalogue();
    hosted: HostedSettings | None = None;
    if app_mode() == HOSTED {
        try {
            hosted = hosted_settings();
        } except HostedSettingsMissing as missing {
            sys.stderr.write(f"{missing}\n");  # jac:ignore[E1099]
            sys.exit(1);
        }
        if os.environ.get("KP_TRANSPORT", "stdio") != "http" {
            sys.stderr.write("Hosted mode serves over HTTP only: set KP_TRANSPORT=http.\n");  # jac:ignore[E1099]
            sys.exit(1);
        }
        # Railway reads each line's level from its JSON, not from its stream.
        use_json_logs();
    }
    # The guest makes the shared Catalog and Format nodes before any user call.
    start();
    # A new catalogue build brings the shared Card nodes up to date; a failure fails the start.
    refresh_cards();

    if os.environ.get("KP_TRANSPORT", "stdio") == "http" {
        http_host = os.environ.get("KP_HTTP_HOST", "127.0.0.1");
        http_port = int(os.environ.get("KP_HTTP_PORT", "8020"));
        check_bind(http_host);
        # Jac's server hands out the page from a child on 127.0.0.1; if it dies, this process exits.
        (child, upstream) = start_upstream(int(os.environ.get("KP_UPSTREAM_PORT", "0")), to_stdout=hosted is not None);
        exit_when_upstream_dies(child);
        stop_child_on_sigterm(child);
        try {
            anyio.run(serve_http, http_host, http_port, upstream, hosted);  # jac:ignore[E1054,W1051]: anyio.run takes *args the checker cannot match
        } finally {
            expect_upstream_to_stop();
            stop_upstream(child);
        }
    } else {
        # stdout carries the MCP protocol, so keep a handle to it and send all
        # other output (walker reports, server logs) to stderr.
        mcp_out = io.TextIOWrapper(os.fdopen(os.dup(1), "wb"), encoding="utf-8", line_buffering=True);
        os.dup2(2, 1);
        sys.stdout = sys.stderr;
        anyio.run(serve_stdio, mcp_out);  # jac:ignore[E1054,W1051]
    }
}
