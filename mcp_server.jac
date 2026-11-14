"""MCP server for Claude Code and Claude Desktop (local stdio or HTTP).

The MCP SDK's MCPServer (FastMCP before mcp 2.0) runs in the same process as
the Jac graph. Deck and format tools each spawn a walker against the app's
shared root, the same root the web app's `:pub` walkers use. Card search,
lookup and name resolution go through the card catalogue module (`cards`).
No tool calls a model.

The web app is a separate process (`jac run`); both share one graph in
Postgres, so decks made in one show in the other at once.
`jac x up` runs both for this worktree.

    claude mcp add knowledge-pool -- jac run --no-serve <repo>/mcp_server.jac

KP_TRANSPORT=http switches the MCP endpoint from stdio to streamable HTTP
(KP_HTTP_HOST, default 127.0.0.1; KP_HTTP_PORT, default 8020), for clients
(e.g. a remote/custom connector) that need a URL instead of a local command.
That endpoint is plain HTTP: it has no TLS of its own, so putting it behind
something that terminates HTTPS (a tunnel like `cloudflared` or `ngrok`, or a
reverse proxy) is up to whoever needs a public https:// URL for it — localhost
is not reachable from a connector that calls in from outside this machine.
"""

import io;
import os;
import sys;
import anyio;
import from datetime { datetime, timezone }
import from mcp.server.mcpserver { MCPServer, Context }
import from mcp.server.apps { Apps, ResourcePermissions, client_supports_apps }
import from mcp_types { CallToolResult, TextContent }
import from mcp.server.stdio { stdio_server }
import from mcp.server.streamable_http { TransportSecuritySettings }
import from cards { search_cards as catalog_search, find_card, resolve_names as catalog_resolve_names, check_catalogue }
import from decks {
    Deck, DeckView, CreateDeck, ListDecks, GetDeck, SetDeckFormat, EditDeck
}
import from deck_io { DeckExport, DeckImport }
import from legality { GetFormatRules }
import from walker_errors { WalkerError }
import from shared_graph { APP_DIR, run_walker }

glob LOGGED_CLIENT_UI: list[bool] = [],
     DECK_UI: str = "ui://knowledge-pool/deck-table.html",
     MANA_UI: str = "ui://knowledge-pool/mana-analysis.html",
     COLOUR_NAMES: dict[str, str] = {"W": "White", "U": "Blue", "B": "Black", "R": "Red", "G": "Green"},
     SEARCH_UI: str = "ui://knowledge-pool/card-search.html",
     EXPORT_UI: str = "ui://knowledge-pool/deck-export.html",
     # The export view's format buttons, in order: key, label, lossless, file
     # extension. Same list as the web app's export panel (export_panel.jac).
     EXPORT_FORMATS: list[dict[str, any]] = [
         {"key": "arena", "label": "MTGA/MTGO", "lossless": False, "ext": "txt"},
         {"key": "moxfield", "label": "Moxfield", "lossless": False, "ext": "txt"},
         {"key": "text", "label": "Plain text", "lossless": False, "ext": "txt"},
         {"key": "mtgdeck1", "label": "mtgdeck/1", "lossless": True, "ext": "json"},
         {"key": "mtgjson", "label": "MTGJSON", "lossless": True, "ext": "json"}
     ],
     LOSSY_DROPS: str = "keeps card names and counts for the main deck and sideboard only. It drops other zones, roles, tags, locks and reasons.";

"""Show a deck to the user as a table in the chat: cards by zone, totals and legality.
Clients that support MCP Apps (Claude Desktop and claude.ai) render it as an HTML list
where each card expands to its rules text, stats, keywords, deck notes and tags; others
get a compact Markdown table. Use deck_get when you only need the data."""
def deck_show(deck_id: str, ctx: Context) -> CallToolResult {
    view = outcome(run_walker(GetDeck(deck_id=deck_id)));
    if "error" in view {
        return CallToolResult(content=[TextContent(text=view["error"])], is_error=True);
    }
    return CallToolResult(
        content=[TextContent(text=view_text(ctx, deck_markdown(view), deck_brief(view)))], structured_content=view
    );
}

"""What the model gets when the user already sees the deck view: the deck's
shape and legality, and a note not to list the cards again."""
def deck_brief(view: dict[str, any]) -> str {
    return (
        f"Shown to the user as an expandable deck list: {view['name']}, {view['format']}, "
        + f"{view['main_total']} main, {view['sideboard_total']} sideboard. "
        + ("Legal. " if view["legal"] else "Not legal: " + "; ".join(v["message"] for v in view["violations"]) + ". ")
        + game_changers_note(view)
        + "The user can see every card, so do not list the cards again; "
        + "call deck_get if you need them to answer a question."
    );
}

"""For a Commander deck, a sentence with its Game Changers and bracket hint
("" for other formats)."""
def game_changers_note(view: dict[str, any]) -> str {
    gc = view.get("game_changers");
    if gc is None {
        return "";
    }
    cards = [str(c) for c in gc["cards"]];
    listed = " (" + ", ".join(cards) + ")" if cards else "";
    return f"Game Changers: {gc['count']}{listed}. Bracket hint from Game Changers only: {gc['bracket_hint']}. ";
}

"""The deck as a compact Markdown table, for clients that do not render MCP
Apps: one row per card, without rules text or tags (get_card has those)."""
def deck_markdown(view: dict[str, any]) -> str {
    lines = [
        f"## {view['name']}",
        f"{view['format']}, {view['main_total']} main, {view['sideboard_total']} sideboard. "
        + ("Legal." if view["legal"] else "Not legal: " + "; ".join(v["message"] for v in view["violations"]))
    ];
    note = game_changers_note(view).strip();
    if note {
        lines.append(note);
    }
    for (zone, title) in [("commander", "Commander"), ("main", "Main deck"), ("sideboard", "Sideboard")] {
        rows = [c for c in view["cards"] if c["zone"] == zone];
        if rows {
            lines += ["", f"### {title}", "", "| # | Card | Cost | Type | P/T |", "|--:|---|---|---|--:|"];
            lines += [
                f"| {c['count']} | {c['name']} | {c['mana_cost']} | {c['type_line']} | {power_toughness(c)} |"
                for c in rows
            ];
        }
    }
    return "\n".join(lines);
}

"""A card line's front-face power/toughness ("2/2"), or "" when it has none."""
def power_toughness(card: any) -> str {
    if not card["power"] and not card["toughness"] {
        return "";
    }
    return f"{card['power']}/{card['toughness']}";
}

"""Mana analysis for a deck: land count, coloured pips (spell demand) and
coloured sources (lands and other cards that produce that colour), plus the
non-land mana curve (card count by mana value, 0-6 and 7+) and its average.
Main deck only - the sideboard is excluded. deck_get and deck_edit return the
same analysis with the whole deck; this tool returns only the analysis.
Clients that support MCP Apps show it as a chart; others get it as Markdown."""
def deck_analyze(deck_id: str, ctx: Context) -> CallToolResult {
    view = deck_get(deck_id);
    if "error" in view {
        return CallToolResult(content=[TextContent(text=view["error"])], is_error=True);
    }
    analysis = {
        "id": view["id"],
        "name": view["name"],
        "format": view["format"],
        "main_total": view["main_total"],
        "mana": view["mana"],
        "curve": view["curve"]
    };
    return CallToolResult(
        content=[TextContent(text=view_text(ctx, mana_markdown(analysis), mana_brief(analysis)))],
        structured_content=analysis
    );
}

"""What the model gets when the user already sees the mana chart: the numbers
on one line, so it can comment on them, and a note not to redraw the chart."""
def mana_brief(analysis: dict[str, any]) -> str {
    mana = analysis["mana"];
    curve = analysis["curve"];
    buckets = curve["buckets"] as dict[str, int];
    used = [c for c in COLOUR_NAMES if mana["pips"].get(c, 0) or mana["sources"].get(c, 0)];
    colours = "; ".join(f"{COLOUR_NAMES[c]} {mana['pips'][c]} pips, {mana['sources'][c]} sources" for c in used);
    return (
        f"Shown to the user as a mana curve and pips-vs-sources chart for {analysis['name']} (main deck): "
        + f"{mana['land_count']} lands, {sum(buckets.values())} non-land cards, "
        + f"average mana value {curve['average_mv']:.2f}; curve "
        + ", ".join(f"{mv}: {n}" for (mv, n) in buckets.items())
        + "; " + (colours or "no coloured mana yet") + ". "
        + "The user can see the chart, so do not repeat these numbers as tables; comment on them if useful."
    );
}

"""The mana analysis as Markdown tables, for clients that do not render MCP Apps."""
def mana_markdown(analysis: dict[str, any]) -> str {
    mana = analysis["mana"];
    curve = analysis["curve"];
    buckets = curve["buckets"] as dict[str, int];
    non_land = sum(buckets.values());
    used = [c for c in COLOUR_NAMES if mana["pips"].get(c, 0) or mana["sources"].get(c, 0)];
    lines = [
        f"## {analysis['name']}: mana ({analysis['format']}, main deck only)",
        f"Lands: {mana['land_count']} · Non-land: {non_land} · Average mana value: {curve['average_mv']:.2f}",
        "",
        "| Mana value | " + " | ".join(buckets.keys()) + " |",
        "|---|" + "|".join("--:" for _ in buckets) + "|",
        "| Cards | " + " | ".join(str(n) for n in buckets.values()) + " |"
    ];
    if used {
        lines += ["", "| Colour | Pips | Sources |", "|---|--:|--:|"];
        lines += [f"| {COLOUR_NAMES[c]} | {mana['pips'][c]} | {mana['sources'][c]} |" for c in used];
    } else {
        lines += ["", "No coloured mana in the main deck yet."];
    }
    return "\n".join(lines);
}

"""Search the catalogue for cards to add to a deck, showing how many copies the deck
already holds in main and sideboard. Every word must match, as a prefix. Clients that
support MCP Apps render a search panel where the user can add hits to the deck
themselves; others get a Markdown table. Use search_cards when no deck is involved."""
def card_search(deck_id: str, query: str, ctx: Context, limit: int = 20) -> CallToolResult {
    view = outcome(run_walker(GetDeck(deck_id=deck_id)));
    if "error" in view {
        return CallToolResult(content=[TextContent(text=view["error"])], is_error=True);
    }
    result = search_with_holdings(view, query, limit);
    if result["error"] {
        return CallToolResult(
            content=[TextContent(text=(result["error"] as str).rstrip(".") + ". The deck is unchanged.")],
            structured_content=result,
            is_error=True
        );
    }
    return CallToolResult(
        content=[TextContent(text=view_text(ctx, search_markdown(result), search_brief(result)))],
        structured_content=result
    );
}

"""What the model gets when the user already sees the search panel: the hits
on one line with oracle ids (so it can still add one when asked in chat), and
a note not to list them again."""
def search_brief(result: dict[str, any]) -> str {
    hits = result["hits"] as list[dict[str, any]];
    query = result["query"] as str;
    if not hits {
        return search_markdown(result);
    }
    refs = [];
    for h in hits {
        in_deck = h["in_deck"] as dict[str, int];
        held = ", ".join(f"{n} {z}" for (z, n) in in_deck.items() if n);
        refs.append(f"{h['name']} ({h['oracle_id']}" + (f"; {held} in deck" if held else "") + ")");
    }
    return (
        f"Shown to the user as a search panel: {len(hits)} {'card matches' if len(hits) == 1 else 'cards match'} "
        + f"\"{query}\". They can add hits to the deck from the panel, and those changes are reported to you. "
        + "Do not list the hits again; for reference: " + "; ".join(refs) + "."
    );
}

"""Search hits for one deck, each with the copies that deck holds per zone
(`in_deck`, e.g. {"main": 2}), plus a short summary of the deck. A catalogue
failure comes back as `error` with no hits."""
def search_with_holdings(view: dict[str, any], query: str, limit: int) -> dict[str, any] {
    held: dict[str, dict[str, int]] = {};
    for c in view["cards"] as list[dict[str, any]] {
        oid = c["oracle_id"] as str;
        zone = c["zone"] as str;
        zones: dict[str, int] = held.get(oid, {});
        zones[zone] = zones.get(zone, 0) + (c["count"] as int);
        held[oid] = zones;
    }
    found = catalog_search(query, limit);
    hits = [{**plain(h), "in_deck": held.get(h.oracle_id, {})} for h in found.hits];
    return {
        "deck": {
            "id": view["id"],
            "name": view["name"],
            "format": view["format"],
            "main_total": view["main_total"],
            "sideboard_total": view["sideboard_total"]
        },
        "query": query,
        "limit": limit,
        "hits": hits,
        "error": found.error
    };
}

"""One Markdown table cell: no pipes or line breaks."""
def md_cell(value: str) -> str {
    return value.replace("|", "\\|").replace("\n", " ");
}

"""Search hits as a Markdown table with an In deck column, for clients that do not
render MCP Apps (and for the model). The oracle ids are there so the model can pass
them straight to deck_edit."""
def search_markdown(result: dict[str, any]) -> str {
    hits = result["hits"] as list[dict[str, any]];
    query = result["query"] as str;
    if not hits {
        return f"No cards match \"{query}\". Every word must match the start of a word in the name, type or rules text.";
    }
    deck_name = (result["deck"] as dict[str, any])["name"] as str;
    lines = [
        f"{len(hits)} {'card matches' if len(hits) == 1 else 'cards match'} \"{query}\" (deck: {deck_name}):",
        "",
        "| Card | Cost | Type | In deck | Oracle id |",
        "|---|---|---|---|---|"
    ];
    for h in hits {
        in_deck = h["in_deck"] as dict[str, int];
        held = ", ".join(f"{n} {z}" for (z, n) in in_deck.items() if n) or "-";
        lines.append(
            f"| {md_cell(h['name'] as str)} | {h['mana_cost']} | {md_cell(h['type_line'] as str)} | {held} | `{h['oracle_id']}` |"
        );
    }
    lines += ["", "Which should I add, how many, and to main or sideboard?"];
    return "\n".join(lines);
}

"""Export a deck as a deck list. Formats: arena (MTGA/MTGO, the default), moxfield
and text are lossy (main deck and sideboard names and counts only); mtgdeck1 and
mtgjson are lossless JSON. Clients that support MCP Apps
show the export in a view with format buttons, Copy and Download; the text result
always carries the full export too. A lossless JSON export is long: the user sees
it in the view, so offer to show it or save it to a file rather than pasting it."""
def deck_export(deck_id: str, ctx: Context, format: str = "arena") -> CallToolResult {
    done = outcome(run_walker(DeckExport(deck_id=deck_id, format=format)));
    if "error" in done {
        return CallToolResult(content=[TextContent(text=done["error"])], structured_content=done, is_error=True);
    }
    result = {
        "deck_id": deck_id,
        "name": done["name"],
        "format": done["format"],
        "content": done["content"],
        "formats": EXPORT_FORMATS,
        "lossy_drops": LOSSY_DROPS
    };
    text = export_text(result);
    return CallToolResult(content=[TextContent(text=view_text(ctx, text, export_brief(result) + text))], structured_content=result);
}

"""The lead-in the model gets when the user already sees the export view. The
export text still follows it, so the model can answer questions about it."""
def export_brief(result: dict[str, any]) -> str {
    return (
        "Shown to the user in the export view, with a button per format, Copy and Download. "
        + "The export below is for your reference only: do not paste it into the chat unless the user asks "
        + "to see it here.\n\n"
    );
}

"""The text a view-bound tool gives the model: `brief` when the client renders
MCP Apps (the user already sees the view, so the full text would only make
the model repeat it), `full` otherwise. Logs the client's advertised
extensions once, to stderr, so it is easy to see which branch a host gets."""
def view_text(ctx: Context, full: str, brief: str) -> str {
    apps = client_supports_apps(ctx);
    if apps not in LOGGED_CLIENT_UI {
        LOGGED_CLIENT_UI.append(apps);
        caps = ctx.client_capabilities;
        sys.stderr.write(  # jac:ignore[E1099]
            f"MCP client renders MCP Apps: {apps} (extensions: {caps.extensions if caps else None})\n"
        );
    }
    return brief if apps else full;
}

"""The export as chat text, for the model and for clients that do not render MCP
Apps. A lossy list goes in a code block with what it drops. A lossless JSON export
leads with a short summary and a hint not to paste it unprompted, then the full
JSON, so a client without the view (Claude Code) can still show or save it."""
def export_text(result: dict[str, any]) -> str {
    label = result["format"];
    lossless = False;
    for f in EXPORT_FORMATS {
        if f["key"] == result["format"] {
            label = f["label"];
            lossless = f["lossless"] as bool;
        }
    }
    content = result["content"] as str;
    if lossless {
        size = f"{len(content.splitlines())} lines, {len(content):,} characters";
        return (
            f"Exported {result['name']} as {label} (lossless, {size}). "
            + "The user can copy or download it from the export view. It is long: offer to show it "
            + "or save it to a file instead of pasting it, unless the user asked to see it.\n\n"
            + f"```json\n{content}\n```"
        );
    }
    return f"Exported {result['name']} as {label}. It {LOSSY_DROPS}\n\n```\n{content}\n```";
}

"""MCP Apps: deck_show, deck_analyze, card_search and deck_export are each bound
to a self-contained HTML view (ui/deck_table.html, ui/mana_analysis.html,
ui/card_search.html, ui/deck_export.html) that the host renders in a sandboxed
iframe and fills from the tool result. The search and export views also call
their tools (and deck_edit) back through the host."""
def make_apps -> Apps {
    apps = Apps();
    apps.tool(resource_uri=DECK_UI)(deck_show);
    apps.tool(resource_uri=MANA_UI)(deck_analyze);
    with open(os.path.join(APP_DIR, "ui", "deck_table.html"), encoding="utf-8") as f {
        apps.add_html_resource(DECK_UI, f.read(), title="Deck table", prefers_border=True);
    }
    with open(os.path.join(APP_DIR, "ui", "mana_analysis.html"), encoding="utf-8") as f {
        apps.add_html_resource(MANA_UI, f.read(), title="Mana analysis", prefers_border=True);
    }
    apps.tool(resource_uri=SEARCH_UI)(card_search);
    with open(os.path.join(APP_DIR, "ui", "card_search.html"), encoding="utf-8") as f {
        apps.add_html_resource(SEARCH_UI, f.read(), title="Card search", prefers_border=True);
    }
    apps.tool(resource_uri=EXPORT_UI)(deck_export);
    with open(os.path.join(APP_DIR, "ui", "deck_export.html"), encoding="utf-8") as f {
        apps.add_html_resource(
            EXPORT_UI, f.read(), title="Deck export", prefers_border=True,
            # Ask for the clipboard so Copy works; the view selects the text when the host says no.
            permissions=ResourcePermissions(clipboard_write={})
        );
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
        + "When the user wants to see a deck, call deck_show; for its mana curve and colours, call deck_analyze. "
        + "When the user wants to find cards to add to a deck, call card_search with that deck's id: it shows "
        + "how many copies the deck already holds, and lets the user add hits themselves; changes they make "
        + "there are reported back to you. To export a deck, call deck_export."
    ),
    extensions=[make_apps()]
);

"""Plain JSON-ready data from walker reports (objs and nodes become dicts)."""
def plain(value: any) -> any {
    if isinstance(value, (list, tuple)) {
        return [plain(v) for v in value];
    }
    if isinstance(value, dict) {
        return {k: plain(v) for (k, v) in value.items()};
    }
    if value is None or isinstance(value, (str, int, float, bool)) {
        return value;
    }
    if hasattr(value, "__dict__") {
        out: dict[str, any] = {k: plain(v) for (k, v) in vars(value).items() if not k.startswith("_")};
        if isinstance(value, Deck) {
            out["id"] = jid(value);
        }
        return out;
    }
    return value;
}

"""A finished walker's result as tool output: its first report as plain data,
or {"error": message, "code": code} when it reported a WalkerError. The
walker says why it failed, so no tool has to guess."""
def outcome(w: any) -> dict[str, any] {
    first = w.reports[0];
    if isinstance(first, WalkerError) {
        return {"error": first.message, "code": first.code};
    }
    return plain(first) as dict[str, any];
}

"""Search card names, type lines and rules text. Every word must match, as a prefix."""
@server.tool()
def search_cards(query: str, limit: int = 20) -> list[dict[str, any]] {
    found = catalog_search(query, limit);
    if found.error {
        raise RuntimeError(found.error);
    }
    return [plain(hit) for hit in found.hits];
}

"""Full card details, by oracle id or exact card name: cost, type line, rules text,
power/toughness, loyalty and defence (front face), keywords, each face of a
multi-face card (name, cost, type, text, stats), format legalities and Scryfall
oracle tags."""
@server.tool()
def get_card(oracle_id_or_name: str) -> dict[str, any] {
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
def resolve_names(names: list[str]) -> dict[str, any] {
    return catalog_resolve_names(names);
}

"""Deck-construction rules for a format: standard, pioneer, modern or commander."""
@server.tool()
def get_format_rules(format: str) -> dict[str, any] {
    return outcome(run_walker(GetFormatRules(format=format)));
}

"""List the user's decks (id, name, format)."""
@server.tool()
def deck_list() -> list[dict[str, any]] {
    decks = plain(run_walker(ListDecks()).reports[0]);
    return [{"id": d["id"], "name": d["name"], "format": d["format"]} for d in decks];
}

"""Create a deck, optionally with seed cards. Each card is
{"oracle_id": ..., "count": n, "zone": "main" | "sideboard" | "commander" | "companion" | "maybeboard", "reason": ...};
get oracle ids from resolve_names first. Returns the deck with its legality."""
@server.tool()
def deck_create(name: str, format: str = "standard", cards: list[dict[str, any]] = []) -> dict[str, any] {
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
def deck_get(deck_id: str) -> dict[str, any] {
    return outcome(run_walker(GetDeck(deck_id=deck_id)));
}

"""Change a deck. Each change is
{"oracle_id": ..., "count": n, "zone": "main" | "sideboard" | "commander" | "companion" | "maybeboard", "reason": "why"}
and sets that card's count in that zone (0 removes it). Every change needs a reason.
Pass "format" to change the deck's format. Changes with an unknown oracle id or no
reason are rejected and listed under "rejected"; the rest are applied."""
@server.tool()
def deck_edit(deck_id: str, changes: list[dict[str, any]] = [], format: str = "") -> dict[str, any] {
    if format {
        reformatted = outcome(run_walker(SetDeckFormat(deck_id=deck_id, format=format)));
        if "error" in reformatted {
            return reformatted;
        }
    }
    return outcome(run_walker(EditDeck(deck_id=deck_id, changes=changes)));
}

"""Check a deck against its format. Returns legal (true or false), each violation and, for a
Commander deck, game_changers (count, cards and a bracket hint; null for other formats)."""
@server.tool()
def deck_validate(deck_id: str) -> dict[str, any] {
    view = deck_get(deck_id);
    if "error" in view {
        return view;
    }
    return {
        "deck_id": deck_id,
        "format": view["format"],
        "legal": view["legal"],
        "violations": view["violations"],
        "game_changers": view["game_changers"]
    };
}

"""Import a deck list, replacing the deck's current cards. Accepts mtgdeck1,
mtgjson (an MTGJSON deck file, such as a precon), text, arena or moxfield. Lines that don't resolve to a known card are listed
under "unresolved" and never added."""
@server.tool()
def deck_import(deck_id: str, format: str, text: str) -> dict[str, any] {
    return outcome(run_walker(DeckImport(deck_id=deck_id, format=format, text=text)));
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
    # Fail before MCP takes stdout: the message goes to stderr.
    check_catalogue();

    if os.environ.get("KP_TRANSPORT", "stdio") == "http" {
        http_host = os.environ.get("KP_HTTP_HOST", "127.0.0.1");
        http_port = int(os.environ.get("KP_HTTP_PORT", "8020"));
        run_any: any = anyio.run;
        run_any(serve_http, http_host, http_port);  # jac:ignore[E1053]
    } else {
        # stdout carries the MCP protocol, so keep a handle to it and send all
        # other output (walker reports, server logs) to stderr.
        mcp_out = io.TextIOWrapper(os.fdopen(os.dup(1), "wb"), encoding="utf-8", line_buffering=True);
        os.dup2(2, 1);
        sys.stdout = sys.stderr;
        run_any2: any = anyio.run;
        run_any2(serve_stdio, mcp_out);  # jac:ignore[E1053]
    }
}
