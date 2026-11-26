"""The MCP tools as plain functions, callable in a test with no MCP server built.

Each tool runs through the runner (`graph_runner.jac`) as whoever is asking and
returns its data, or raises `ToolFailure` with a walker error. `adapted` turns
either into the one tool result the connector sees; `mcp_server.jac` registers
the tools through it, and a test calls them through it the same way. The text a
view-bound tool gives the model is built in `mcp_builders.jac`.
"""

import json;
import logging;
import sys;
import from functools { wraps }
import from mcp.server.mcpserver { Context }
import from mcp.server.apps { client_supports_apps }
import from mcp_types { CallToolResult, TextContent }
import from cards { CardSearch, search_cards as catalog_search, find_card, resolve_names as catalog_resolve_names }
import from decks { Deck, CreateDeck, ListDecks, ListOtherDecks, CopyOtherDeck, GetDeck, EditDeck }
import from deckformats { export_format_choices }
import from zones { zone_choices, zone_options }
import from deck_io { DeckExport, DeckImport }
import from deck_operations { perform }
import from collection { GetCollection, ChangeCollection }
import from collection_views { MODE_ADD }
import from legality { GetFormatRules }
import from walker_errors { WalkerError }
import from json_object { JsonObject }
import from mcp_builders { deck_brief, deck_markdown, mana_brief, mana_markdown, search_brief, search_markdown, export_brief, export_text, LOSSY_DROPS }
import from graph_runner { HOSTED, app_mode, call_function }
import from gatekeeper { request_caller }
import from jaclang.runtime.constructs { WalkerArchetype }

glob LOGGED_CLIENT_UI: list[bool] = [];

"""Fill the {zones} and {formats} placeholders in a tool's description from the zones
module and the deckformats package, so a new zone or format reaches it with no edit."""
def with_choices(tool: Callable) -> Callable {
    formats = ", ".join(
        [f"{f['key']} ({f['label']}, {'lossless' if f['lossless'] else 'lossy'})" for f in export_format_choices()]
    );
    tool.__doc__ = (tool.__doc__ or "").replace("{zones}", zone_options()).replace("{formats}", formats);
    return tool;
}

"""A tool that cannot give its result: `error` is the walker error the caller
gets. Raised by `outcome` and `ask`; `adapted` turns it into the tool result."""
obj ToolFailure(Exception) {
    has error: WalkerError;

    def postinit {
        super.init(self.error.message);
    }
}

"""A failed tool's one result shape, whichever tool failed: `is_error` with the
message as its text and `{error, code}` as its structured content."""
def tool_error(error: WalkerError) -> CallToolResult {
    return CallToolResult(
        content=[TextContent(text=error.message)],
        structured_content={"error": error.message, "code": error.code},
        is_error=True
    );
}

"""A tool's data as its result: the JSON as text, and as structured content in
the SDK's {"result": ...} wrapper, the way it wraps every return type that is
not a plain dict (`JsonObject` is an alias, so a deck is wrapped too)."""
def tool_success(data: object) -> CallToolResult {
    return CallToolResult(content=[TextContent(text=json.dumps(data, indent=2))], structured_content={"result": data});
}

"""`f` as a tool: what it returns is its result and a `ToolFailure` it raises is
the failure result, the one place that makes a tool result from either. It keeps
`f`'s signature and annotations, so the SDK still reads the tool from them."""
def adapted(f: Callable) -> Callable {
    @wraps(f)
    def run(*args: any, **kwargs: any) -> CallToolResult {  # jac:ignore[W1037]
        try {
            done = f(*args, **kwargs);
        } except ToolFailure as failed {
            return tool_error(failed.error);
        }
        return done if isinstance(done, CallToolResult) else tool_success(done);
    }
    return run;
}

"""Show a deck to the user as a table in the chat: cards by zone, totals and legality.
Clients that support MCP Apps (Claude Desktop and claude.ai) render it as an HTML list
where each card expands to its rules text, stats, keywords, deck notes and tags; others
get a compact Markdown table. Use deck_get when you only need the data."""
def deck_show(deck_id: str, ctx: Context) -> CallToolResult {  # jac:ignore[W1036]: the SDK finds the context by this bare annotation
    view = outcome(perform(request_caller(), GetDeck(deck_id=deck_id)));
    return view_result(ctx, {**view, "zones": zone_choices()}, deck_markdown(view), deck_brief(view));
}

"""Mana analysis for a deck: land count, coloured pips (spell demand) and
coloured sources (lands and other cards that produce that colour), plus the
non-land mana curve (card count by mana value, 0-6 and 7+) and its average.
Main deck only - the sideboard is excluded. deck_get and deck_edit return the
same analysis with the whole deck; this tool returns only the analysis.
Clients that support MCP Apps show it as a chart; others get it as Markdown."""
def deck_analyze(deck_id: str, ctx: Context) -> CallToolResult {  # jac:ignore[W1036]: the SDK finds the context by this bare annotation
    view = deck_get(deck_id);
    analysis = {
        "id": view["id"],
        "name": view["name"],
        "format": view["format"],
        "main_total": view["main_total"],
        "mana": view["mana"],
        "curve": view["curve"]
    };
    return view_result(ctx, analysis, mana_markdown(analysis), mana_brief(analysis));
}

"""Search the catalogue for cards to add to a deck, showing how many copies the deck
already holds in main and sideboard. Every word must match, as a prefix. Clients that
support MCP Apps render a search panel where the user can add hits to the deck
themselves; others get a Markdown table. Use search_cards when no deck is involved."""
def card_search(deck_id: str, query: str, ctx: Context, limit: int = 20) -> CallToolResult {  # jac:ignore[W1036]: the SDK finds the context by this bare annotation
    view = outcome(perform(request_caller(), GetDeck(deck_id=deck_id)));
    result = search_with_holdings(view, query, limit);
    if result["error"] {
        raise card_search_failure(result["error"] as str);
    }
    return view_result(ctx, result, search_markdown(result), search_brief(result));
}

"""Search hits for one deck, each with the copies that deck holds per zone
(`in_deck`, e.g. {"main": 2}), plus a short summary of the deck. `mine` is
whether the caller owns the deck: the view offers its Add buttons only then. A
catalogue failure comes back as `error` with no hits."""
def search_with_holdings(view: JsonObject, query: str, limit: int) -> JsonObject {
    held: dict[str, dict[str, int]] = {};
    for c in view["cards"] as list[JsonObject] {
        oid = c["oracle_id"] as str;
        zone = c["zone"] as str;
        zones: dict[str, int] = held.get(oid, {});
        zones[zone] = zones.get(zone, 0) + (c["count"] as int);
        held[oid] = zones;
    }
    found = catalog_search(query, limit);
    hits = [{**(plain(h) as JsonObject), "in_deck": held.get(h.oracle_id, {})} for h in found.hits];
    return {
        "deck": {
            "id": view["id"],
            "name": view["name"],
            "format": view["format"],
            "main_total": view["main_total"],
            "sideboard_total": view["sideboard_total"],
            "mine": view["mine"]
        },
        "query": query,
        "limit": limit,
        "hits": hits,
        "error": found.error
    };
}

"""Export a deck as a deck list. Formats: {formats}. A lossy list keeps main deck and
sideboard names and counts only; a lossless one is JSON that keeps everything. The default is arena. Clients that support MCP Apps
show the export in a view with format buttons, Copy and Download; the text result
always carries the full export too. A lossless JSON export is long: the user sees
it in the view, so offer to show it or save it to a file rather than pasting it."""
@with_choices
def deck_export(deck_id: str, ctx: Context, format: str = "arena") -> CallToolResult {  # jac:ignore[W1036]: the SDK finds the context by this bare annotation
    done = outcome(perform(request_caller(), DeckExport(deck_id=deck_id, format=format)));
    result = {
        "deck_id": deck_id,
        "name": done["name"],
        "format": done["format"],
        "content": done["content"],
        "formats": export_format_choices(),
        "lossy_drops": LOSSY_DROPS
    };
    text = export_text(result);
    return view_result(ctx, result, text, export_brief() + text);
}

"""The text a view-bound tool gives the model: `brief` when the client renders
MCP Apps (the user already sees the view, so the full text would only make
the model repeat it), `full` otherwise. Logs the client's advertised
extensions once, to stderr (to the info log when hosted), so it is easy to see which branch a host gets."""
def view_text(ctx: Context, full: str, brief: str) -> str {  # jac:ignore[W1036]: the SDK finds the context by this bare annotation
    apps = client_supports_apps(ctx);
    if apps not in LOGGED_CLIENT_UI {
        LOGGED_CLIENT_UI.append(apps);
        caps = ctx.client_capabilities;
        note = f"MCP client renders MCP Apps: {apps} (extensions: {caps.extensions if caps else None})";
        if app_mode() == HOSTED {
            # Hosted logs are JSON on stdout, where this routine note is info (`log_setup.jac`).
            logging.getLogger("knowledge_pool.mcp").info(note);
        } else {
            sys.stderr.write(note + "\n");  # jac:ignore[E1099]
        }
    }
    return brief if apps else full;
}

"""A view-bound tool's result: `view_text`'s text, plus `data` as structured
content for the view, only when the client renders MCP Apps. Some clients
without MCP Apps (Claude Code among them) give the model the structured content
in place of the text, so sending it there would swap the Markdown for raw JSON."""
def view_result(ctx: Context, data: JsonObject, full: str, brief: str) -> CallToolResult {  # jac:ignore[W1036]: the SDK finds the context by this bare annotation
    return CallToolResult(
        content=[TextContent(text=view_text(ctx, full, brief))],
        structured_content=data if client_supports_apps(ctx) else None
    );
}

"""Call `f` through the runner as whoever is asking, for the tools that
read only the card catalogue. A call the runner could not finish fails the tool."""
def ask(f: Callable[[], object]) -> object {
    done = call_function(request_caller(), f);
    if isinstance(done, WalkerError) {
        raise ToolFailure(error=done);
    }
    return done;
}

"""Plain JSON-ready data from walker reports (objs and nodes become dicts)."""
def plain(value: object) -> object {
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
        out: JsonObject = {k: plain(v) for (k, v) in vars(value).items() if not k.startswith("_")};
        if isinstance(value, Deck) {
            out["id"] = jid(value);
        }
        return out;
    }
    return value;
}

"""A finished walker's first report as plain data. When it reported a
WalkerError the tool fails with it (`ToolFailure`): the walker says why, so no
tool has to guess."""
def outcome(w: WalkerArchetype) -> JsonObject {
    first = w.reports[0];
    if isinstance(first, WalkerError) {
        raise ToolFailure(error=first);
    }
    return plain(first) as JsonObject;
}

"""A finished walker's first report as a list of plain data, failing the tool
with a WalkerError report as `outcome` does."""
def outcome_list(w: WalkerArchetype) -> list[JsonObject] {
    first = w.reports[0];
    if isinstance(first, WalkerError) {
        raise ToolFailure(error=first);
    }
    return plain(first) as list[JsonObject];
}

"""The tool failure for a catalogue search that could not run, with its message."""
def card_search_failure(message: str) -> ToolFailure {
    return ToolFailure(error=WalkerError(code="card-search-failed", message=message));
}

"""Search card names, type lines and rules text. Every word must match, as a prefix."""
def search_cards(query: str, limit: int = 20) -> list[JsonObject] {
    found = ask(lambda () -> object { return catalog_search(query, limit); }) as CardSearch;
    if found.error {
        raise card_search_failure(found.error);
    }
    return [plain(hit) as JsonObject for hit in found.hits];
}

"""Full card details, by oracle id or exact card name: cost, type line, rules text,
power/toughness, loyalty and defence (front face), keywords, each face of a
multi-face card (name, cost, type, text, stats), format legalities and Scryfall
oracle tags."""
def get_card(oracle_id_or_name: str) -> JsonObject {
    card = ask(lambda () -> object { return find_card(oracle_id_or_name); }) as JsonObject | None;
    if card is None {
        raise ToolFailure(
            error=WalkerError(
                code="no-such-card", message=f"No card matches {oracle_id_or_name}. Try resolve_names or search_cards."
            )
        );
    }
    return card;
}

"""Match card names to oracle ids. Returns `exact` matches, `fuzzy` matches with
candidates to choose from, and `unknown` names. Only exact matches (or a candidate
the user confirms) should go into a deck."""
def resolve_names(names: list[str]) -> JsonObject {
    return ask(lambda () -> object { return catalog_resolve_names(names); }) as JsonObject;
}

"""Deck-construction rules for a format: standard, pioneer, modern or commander."""
def get_format_rules(format: str) -> JsonObject {
    return outcome(perform(request_caller(), GetFormatRules(format=format)));
}

"""List the user's decks (id, name, format)."""
def deck_list -> list[JsonObject] {
    decks = outcome_list(perform(request_caller(), ListDecks()));
    return [{"id": d["id"], "name": d["name"], "format": d["format"]} for d in decks];
}

"""List other users' decks (id, deck name, format and the owner's display name),
never your own. Every user can see and copy every deck, but only its owner can
change it: pass an id to deck_get or deck_show to look at one, or to deck_copy to
make your own copy to change."""
def deck_browse -> list[JsonObject] {
    others = outcome_list(perform(request_caller(), ListOtherDecks()));
    return [{"id": d["id"], "name": d["name"], "format": d["format"], "owner": d["owner"]} for d in others];
}

"""Copy any user's deck (see deck_browse for ids) into your own decks as
"<name> (copy)": its cards, zones, counts, format and per-card notes, with its own
history starting from one line saying it was copied. The copy is yours to change
and is not tied to the original. Returns the new deck."""
def deck_copy(deck_id: str) -> JsonObject {
    return outcome(perform(request_caller(), CopyOtherDeck(deck_id=deck_id)));
}

"""Create a deck, optionally with seed cards. Each card is
{"oracle_id": ..., "count": n, "zone": {zones}, "reason": ...};
get oracle ids from resolve_names first. Returns the deck with its legality."""
@with_choices
def deck_create(name: str, format: str = "standard", cards: list[JsonObject] | None = None) -> JsonObject {
    changes = [{**c, "reason": c.get("reason") or "seed card"} for c in cards or []];
    made = outcome(perform(request_caller(), CreateDeck(name=name, format=format, changes=changes)));
    if cards {
        return made;
    }
    return deck_get(str(made["id"]));
}

"""A deck, yours or another user's: its cards, totals, legality and recent change history."""
def deck_get(deck_id: str) -> JsonObject {
    return outcome(perform(request_caller(), GetDeck(deck_id=deck_id)));
}

"""Change one of your own decks (another user's answers not-your-deck: copy it first). Each change is
{"oracle_id": ..., "count": n, "zone": {zones}, "reason": "why"}
and sets that card's count in that zone (0 removes it); add "mode": "add" to add `count`
copies on top of what the zone already holds instead. Every change needs a reason.
Pass "format" to change the deck's format, and "name" to rename it (trimmed; a blank name is refused;
the history gets one "Renamed from X to Y" line). The whole call is one commit: a refused rename or
format leaves the deck as it was. Changes with an unknown oracle id or no
reason are rejected and listed under "rejected"; the rest are applied."""
@with_choices
def deck_edit(deck_id: str, changes: list[JsonObject] | None = None, format: str = "", name: str | None = None) -> JsonObject {
    return outcome(
        perform(request_caller(), EditDeck(deck_id=deck_id, name=name, format=format or None, changes=changes or []))
    );
}

"""Check a deck against its format. Returns legal (true or false), each violation and, for a
Commander deck, game_changers (count, cards and a bracket hint; null for other formats)."""
def deck_validate(deck_id: str) -> JsonObject {
    view = deck_get(deck_id);
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
def deck_import(deck_id: str, format: str, text: str) -> JsonObject {
    return outcome(perform(request_caller(), DeckImport(deck_id=deck_id, format=format, text=text)));
}

"""Your collection: the cards you have, card by card with counts, and the history of
its changes with their reasons. Counts are per oracle card, not per printing."""
def collection_get -> JsonObject {
    return outcome(perform(request_caller(), GetCollection()));
}

"""Change how many copies of a card your collection has. `mode` is "add" (`count`
more copies, the default), "remove" (`count` fewer) or "set" (exactly `count`;
0 takes the card out). Every change needs a reason (for example "bought at FNM").
Removing more copies than you have is refused with `refused-change`, saying how many
you have, and changes nothing. Get oracle ids from resolve_names. Returns your
collection. Changing a deck never changes your collection."""
def collection_change(oracle_id: str, count: int, reason: str, mode: str = MODE_ADD) -> JsonObject {
    return outcome(perform(request_caller(), ChangeCollection(oracle_id=oracle_id, count=count, mode=mode, reason=reason)));
}
