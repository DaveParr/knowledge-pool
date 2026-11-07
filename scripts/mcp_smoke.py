"""End-to-end check of the MCP server over stdio, and of sharing decks with the web app.

    uv run python scripts/mcp_smoke.py [port]

Starts `jac run mcp_server.jac` as an MCP client would, builds a deck through
the tools, checks it through the web app's REST API in the same process, then
makes a deck in the web app and finds it through MCP.
"""

import json
import os
import sys
import time
import urllib.request
from pathlib import Path

import anyio
from mcp.client.session import ClientSession
from mcp.client.stdio import StdioServerParameters, stdio_client

ROOT = Path(__file__).resolve().parent.parent
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8828


def web(path: str, body: dict | None = None) -> dict:
    req = urllib.request.Request(
        f"http://127.0.0.1:{PORT}{path}",
        data=json.dumps(body or {}).encode(),
        headers={"Content-Type": "application/json"},
    )
    return json.load(urllib.request.urlopen(req, timeout=30))


def wait_for_web() -> None:
    for _ in range(120):
        try:
            urllib.request.urlopen(f"http://127.0.0.1:{PORT}/healthz", timeout=2)
            return
        except OSError:
            time.sleep(1)
    raise SystemExit("web app did not come up")


async def call(session: ClientSession, tool: str, **args):
    result = await session.call_tool(tool, args)
    assert not result.is_error, (tool, result.content)
    if result.structured_content is not None:
        sc = result.structured_content
        return sc.get("result", sc) if isinstance(sc, dict) and set(sc) == {"result"} else sc
    return json.loads(result.content[0].text)


def check(label: str, ok: bool, detail="") -> None:
    print(("PASS " if ok else "FAIL ") + label + (f": {detail}" if detail and not ok else ""))
    if not ok:
        raise SystemExit(1)


async def main() -> None:
    params = StdioServerParameters(
        command="uv",
        args=["run", "jac", "run", "mcp_server.jac"],
        cwd=str(ROOT),
        env={**os.environ, "KP_PORT": str(PORT)},
    )
    async with stdio_client(params) as (read, write), ClientSession(read, write) as session:
        await session.initialize()
        tools = sorted(t.name for t in (await session.list_tools()).tools)
        print("tools:", ", ".join(tools))
        check("all eleven tools from the issue are listed", {
            "search_cards", "get_card", "resolve_names", "get_format_rules",
            "deck_create", "deck_get", "deck_edit", "deck_validate", "deck_analyze",
            "deck_export", "deck_import",
        } <= set(tools))

        resolved = await call(session, "resolve_names", names=["Lightning Bolt", "Goblin Guide", "Lightening Bolt", "Flargle the Unreal", "Mountain"])
        check("exact names resolve", [e["name"] for e in resolved["exact"]] == ["Lightning Bolt", "Goblin Guide", "Mountain"], resolved)
        check("misspelling comes back as fuzzy with candidates", resolved["fuzzy"][0]["input"] == "Lightening Bolt" and resolved["fuzzy"][0]["candidates"][0]["name"] == "Lightning Bolt", resolved)
        check("invented card is unknown", resolved["unknown"] == ["Flargle the Unreal"], resolved)
        ids = {e["name"]: e["oracle_id"] for e in resolved["exact"]}

        rules = await call(session, "get_format_rules", format="modern")
        check("format rules", rules["min_main"] == 60 and rules["copy_limit"] == 4 and rules["sideboard_max"] == 15, rules)

        hits = await call(session, "search_cards", query="deals 3 damage to any target", limit=5)
        check("search_cards returns cards", len(hits) > 0, hits)

        deck = await call(session, "deck_create", name="MCP Burn", format="modern", cards=[
            {"oracle_id": ids["Lightning Bolt"], "count": 4, "zone": "main", "reason": "seed: efficient burn"},
            {"oracle_id": ids["Goblin Guide"], "count": 4, "zone": "main", "reason": "seed: fast threat"},
        ])
        check("deck created from seed cards", {c["name"]: c["count"] for c in deck["cards"]} == {"Lightning Bolt": 4, "Goblin Guide": 4}, deck)
        check("new deck is not yet legal (8 cards)", deck["legal"] is False)

        deck = await call(session, "deck_edit", deck_id=deck["id"], changes=[
            {"oracle_id": ids["Mountain"], "count": 52, "zone": "main", "reason": "mana base"},
            {"oracle_id": "made-up-id", "count": 4, "zone": "main", "reason": "invented"},
            {"oracle_id": ids["Lightning Bolt"], "count": 2, "zone": "sideboard"},
        ])
        check("invented id and missing reason are rejected", len(deck["rejected"]) == 2, deck["rejected"])
        check("good change applied", deck["main_total"] == 60, deck)
        check("each change is logged with its reason", [h["reason"] for h in deck["history"]] == ["seed: efficient burn", "seed: fast threat", "mana base"], deck["history"])

        verdict = await call(session, "deck_validate", deck_id=deck["id"])
        check("deck_validate says legal", verdict["legal"] is True and verdict["violations"] == [], verdict)

        analysis = await call(session, "deck_analyze", deck_id=deck["id"])
        check("deck_analyze buckets the 4x Bolt and 4x Goblin Guide at mv 1", analysis["curve"]["buckets"]["1"] == 8, analysis)
        check("deck_analyze excludes the 52 Mountain from the curve", analysis["curve"]["average_mv"] == 1.0, analysis)
        check(
            "deck_analyze reports the mana base",
            analysis["mana"]["land_count"] == 52
            and analysis["mana"]["pips"]["R"] == 8
            and analysis["mana"]["sources"]["R"] == 52,
            analysis,
        )

        deck = await call(session, "deck_edit", deck_id=deck["id"], format="standard")
        verdict = await call(session, "deck_validate", deck_id=deck["id"])
        check("switching to Standard makes it illegal, with reasons", not verdict["legal"] and {v["rule"] for v in verdict["violations"]} == {"not-legal"}, verdict)

        exported = await call(session, "deck_export", deck_id=deck["id"], format="mtgdeck1")
        check("export produces an mtgdeck/1 document", json.loads(exported["content"])["schema"] == "mtgdeck/1", exported)

        reimported = await call(session, "deck_import", deck_id=deck["id"], format="mtgdeck1", text=exported["content"])
        check("round-trip import resolves every entry", reimported["unresolved"] == [], reimported)
        check("round-trip import keeps the same main total", reimported["deck"]["main_total"] == deck["main_total"], reimported)

        listed_tools = {t.name: t for t in (await session.list_tools()).tools}
        ui_uri = ((listed_tools["deck_show"].meta or {}).get("ui") or {}).get("resourceUri")
        check("deck_show points at a ui:// resource", ui_uri == "ui://knowledge-pool/deck-table.html", listed_tools["deck_show"].meta)
        page = (await session.read_resource(ui_uri)).contents[0]
        check("the deck view is served as an MCP App", page.mime_type == "text/html;profile=mcp-app" and "ui/initialize" in page.text, page.mime_type)
        shown = await session.call_tool("deck_show", {"deck_id": deck["id"]})
        check("deck_show gives the view the deck data", shown.structured_content["main_total"] == 60, shown.structured_content)
        check("deck_show gives other clients a Markdown table", "| 52 | Mountain |" in shown.content[0].text, shown.content[0].text)

        wait_for_web()
        web_decks = web("/walker/ListDecks")["data"]["reports"][0]
        check("deck made over MCP shows in the web app", "MCP Burn" in [d["name"] for d in web_decks], web_decks)
        web_view = web("/walker/GetDeck", {"deck_id": deck["id"]})["data"]["reports"][0]
        check("web app sees the same cards", web_view["main_total"] == 60, web_view)

        web("/walker/CreateDeck", {"name": "Made in the app", "format": "pioneer"})
        listed = await call(session, "deck_list")
        check("deck made in the web app shows over MCP", "Made in the app" in [d["name"] for d in listed], listed)

    print("all checks passed")


anyio.run(main)
