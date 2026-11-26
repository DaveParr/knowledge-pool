"""End-to-end check of the MCP server over stdio, in local mode: the transport,
the tool list and the MCP Apps wiring. What each tool does is tested in process
(`tests/test_mcp_tools.py`); this script only proves that a client reaches them.

    jac run --no-serve scripts/mcp_smoke.py

Starts `jac run mcp_server.jac` as an MCP client would, on this worktree's
database (or `JAC_DB_URL`), and makes a deck through a tool. Then a second MCP
server process on the same database finds the deck: both run every call as the
local user.
"""

import json
import os
import sys
from pathlib import Path

import anyio
from mcp.client.session import ClientSession
from mcp.client.stdio import StdioServerParameters, stdio_client

ROOT = Path(__file__).resolve().parent.parent
JAC = sys.executable  # the jac binary runs this script
MCP_SERVER = StdioServerParameters(
    command=JAC, args=["run", "--no-serve", "mcp_server.jac"], cwd=str(ROOT), env=dict(os.environ),
)

TOOLS = {
    "search_cards", "get_card", "resolve_names", "get_format_rules",
    "deck_list", "deck_browse", "deck_copy", "deck_create", "deck_get", "deck_edit",
    "deck_validate", "deck_import", "deck_show", "deck_analyze", "card_search", "deck_export",
    "collection_get", "collection_change", "collection_import", "user_list", "collection_browse",
}
# The tools bound to an MCP Apps view, and the view each opens.
VIEWS = {
    "deck_show": "ui://knowledge-pool/deck-table.html",
    "deck_analyze": "ui://knowledge-pool/mana-analysis.html",
    "card_search": "ui://knowledge-pool/card-search.html",
    "deck_export": "ui://knowledge-pool/deck-export.html",
}
APP_MIME_TYPE = "text/html;profile=mcp-app"


def check(label: str, ok: bool, detail="") -> None:
    print(("PASS " if ok else "FAIL ") + label + (f": {detail}" if detail and not ok else ""))
    if not ok:
        raise SystemExit(1)


def data(result):
    sc = result.structured_content
    return sc["result"] if sc is not None and set(sc) == {"result"} else sc or json.loads(result.content[0].text)


async def main() -> None:
    async with stdio_client(MCP_SERVER) as (read, write), ClientSession(read, write) as session:
        await session.initialize()
        listed = {t.name: t for t in (await session.list_tools()).tools}
        print("tools:", ", ".join(sorted(listed)))
        check("exactly the tools are listed", set(listed) == TOOLS, sorted(set(listed) ^ TOOLS))

        for tool, uri in VIEWS.items():
            ui = (listed[tool].meta or {}).get("ui") or {}
            check(f"{tool} points at its ui:// view", ui.get("resourceUri") == uri, listed[tool].meta)
            page = (await session.read_resource(uri)).contents[0]
            check(f"{tool}'s view is served as an MCP App", page.mime_type == APP_MIME_TYPE and "ui/initialize" in page.text, page.mime_type)
            check(f"{tool}'s view has the shared refusal helpers", "function refusalOf(" in page.text and "@include" not in page.text)
        export_page = (await session.read_resource(VIEWS["deck_export"])).contents[0]
        check("the export view asks for clipboard access", ((export_page.meta or {}).get("ui") or {}).get("permissions") == {"clipboardWrite": {}}, export_page.meta)
        search_page = (await session.read_resource(VIEWS["card_search"])).contents[0]
        check("the card search view calls tools back through the host", all(m in search_page.text for m in ("tools/call", "deck_edit")))

        resolved = data(await session.call_tool("resolve_names", {"names": ["Lightning Bolt", "Goblin Guide"]}))
        cards = [{"oracle_id": e["oracle_id"], "count": 4, "zone": "main", "reason": "seed"} for e in resolved["exact"]]
        made = await session.call_tool("deck_create", {"name": "MCP Burn", "format": "modern", "cards": cards})
        check("a tool call over the transport makes a deck", not made.is_error and data(made)["name"] == "MCP Burn", made.content)
        deck_id = data(made)["id"]

        added = await session.call_tool(
            "collection_change", {"oracle_id": cards[0]["oracle_id"], "count": 2, "reason": "smoke"}
        )
        check("a tool call over the transport adds to the collection", not added.is_error and data(added)["total"] >= 2, added.content)
        kept = data(await session.call_tool("collection_get", {}))
        check("collection_get reads the collection back", cards[0]["oracle_id"] in [c["oracle_id"] for c in kept["cards"]], kept)

        others = data(await session.call_tool("user_list", {}))
        check("user_list lists users by handle and name only", all(set(u) == {"handle", "name"} for u in others), others)
        unknown = await session.call_tool("collection_browse", {"handle": "no-such-handle"})
        check(
            "collection_browse of an unknown handle is a tool error with its code",
            unknown.is_error and unknown.structured_content["code"] == "no-such-user", unknown.content,
        )
        pasted = data(await session.call_tool("collection_import", {"format": "text", "text": "3 Goblin Guide\n\nSideboard\n1 Goblin Guide\n1 Not A Real Card\n"}))
        guides = [c["count"] for c in pasted["collection"]["cards"] if c["name"] == "Goblin Guide"]
        check("collection_import adds a pasted list, summing zones", guides == [4], pasted)
        check("collection_import reports names that resolve to no card", any("Not A Real Card" in u for u in pasted["unresolved"]), pasted)

        failed = await session.call_tool("deck_get", {"deck_id": "nope"})
        check(
            "a failure crosses the transport as a tool error with its code",
            failed.is_error and failed.structured_content == {"error": "No deck with id nope.", "code": "no-such-deck"},
            (failed.content, failed.structured_content),
        )
        shown = await session.call_tool("deck_show", {"deck_id": deck_id})
        check("a client without MCP Apps gets Markdown and no structured content", shown.structured_content is None and "| 4 (4 owned) | Goblin Guide |" in shown.content[0].text, shown.content)

    # A client that renders MCP Apps already shows the view, so the model gets a
    # short brief and the view gets the data. A second MCP server process on the
    # same database, as the same local user.
    apps_ext = {"io.modelcontextprotocol/ui": {"mimeTypes": [APP_MIME_TYPE]}}
    async with stdio_client(MCP_SERVER) as (read, write), ClientSession(read, write, extensions=apps_ext) as session:
        await session.initialize()
        decks = data(await session.call_tool("deck_list", {}))
        check("a second MCP server process lists the local user's deck", "MCP Burn" in [d["name"] for d in decks], decks)
        shown = await session.call_tool("deck_show", {"deck_id": deck_id})
        check(
            "a client with MCP Apps gets a brief and the deck as structured content",
            shown.content[0].text.startswith("Shown to the user as an expandable deck list: MCP Burn")
            and shown.structured_content["main_total"] == 8,
            (shown.content, shown.structured_content),
        )

    print("all checks passed")


anyio.run(main)
