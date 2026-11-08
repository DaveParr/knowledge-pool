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
        check("all the tools are listed", {
            "search_cards", "get_card", "resolve_names", "get_format_rules",
            "deck_create", "deck_get", "deck_edit", "deck_validate", "deck_analyze",
            "deck_export", "deck_import", "deck_show", "card_search",
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
        check(
            "deck_analyze is the deck's analysis only, not its cards",
            set(analysis) == {"id", "name", "format", "main_total", "mana", "curve"}
            and analysis["name"] == "MCP Burn" and analysis["main_total"] == 60,
            analysis,
        )
        check("deck_edit already carried the same curve", deck["curve"] == analysis["curve"], deck)

        deck = await call(session, "deck_edit", deck_id=deck["id"], format="standard")
        check("a format change still reports the curve", deck["curve"] == analysis["curve"], deck)
        verdict = await call(session, "deck_validate", deck_id=deck["id"])
        check("switching to Standard makes it illegal, with reasons", not verdict["legal"] and {v["rule"] for v in verdict["violations"]} == {"not-legal"}, verdict)

        exported = await call(session, "deck_export", deck_id=deck["id"], format="mtgdeck1")
        check("export produces an mtgdeck/1 document", json.loads(exported["content"])["schema"] == "mtgdeck/1", exported)

        arena = await session.call_tool("deck_export", {"deck_id": deck["id"]})
        check("deck_export defaults to MTGA/MTGO (arena)", arena.structured_content["format"] == "arena" and arena.structured_content["content"].startswith("Deck\n"), arena.structured_content)
        check("deck_export names the deck for the view", arena.structured_content["name"] == "MCP Burn" and arena.structured_content["deck_id"] == deck["id"], arena.structured_content)
        check(
            "deck_export lists every format with its lossless flag",
            {f["key"]: f["lossless"] for f in arena.structured_content["formats"]}
            == {"arena": False, "moxfield": False, "text": False, "mtgdeck1": True, "mtgjson": True},
            arena.structured_content["formats"],
        )
        check(
            "a lossy export's text gives the list in a code block and says what it drops",
            "```\nDeck\n" in arena.content[0].text and "drops other zones, roles, tags, locks and reasons" in arena.content[0].text,
            arena.content[0].text,
        )
        lossless = await session.call_tool("deck_export", {"deck_id": deck["id"], "format": "mtgdeck1"})
        lossless_text = lossless.content[0].text
        check("a lossless export's text starts with a short summary", lossless_text.startswith("Exported MCP Burn as mtgdeck/1 (lossless,"), lossless_text[:200])
        check("a lossless export's text still carries the whole JSON", lossless.structured_content["content"] in lossless_text, lossless_text[:200])
        export_tool = {t.name: t for t in (await session.list_tools()).tools}["deck_export"]
        export_uri = ((export_tool.meta or {}).get("ui") or {}).get("resourceUri")
        check("deck_export points at the export view", export_uri == "ui://knowledge-pool/deck-export.html", export_tool.meta)
        export_page = (await session.read_resource(export_uri)).contents[0]
        check("the export view is served as an MCP App", export_page.mime_type == "text/html;profile=mcp-app" and "tools/call" in export_page.text, export_page.mime_type)
        check("the export view asks for clipboard access", ((export_page.meta or {}).get("ui") or {}).get("permissions") == {"clipboardWrite": {}}, export_page.meta)
        export_missing = await session.call_tool("deck_export", {"deck_id": "nope"})
        check(
            "deck_export gives an unknown deck as a tool error with its code",
            export_missing.is_error and export_missing.content[0].text == "No deck with id nope."
            and export_missing.structured_content == {"error": "No deck with id nope.", "code": "no-such-deck"},
            (export_missing.content, export_missing.structured_content),
        )
        export_bad = await session.call_tool("deck_export", {"deck_id": deck["id"], "format": "cockatrice"})
        check("deck_export gives an unknown list format as a tool error", export_bad.is_error and export_bad.structured_content["code"] == "unknown-list-format", export_bad.structured_content)

        reimported = await call(session, "deck_import", deck_id=deck["id"], format="mtgdeck1", text=exported["content"])
        check("round-trip import resolves every entry", reimported["unresolved"] == [], reimported)
        check("round-trip import keeps the same main total", reimported["deck"]["main_total"] == deck["main_total"], reimported)

        listed_tools = {t.name: t for t in (await session.list_tools()).tools}
        ui_uri = ((listed_tools["deck_show"].meta or {}).get("ui") or {}).get("resourceUri")
        check("deck_show points at a ui:// resource", ui_uri == "ui://knowledge-pool/deck-table.html", listed_tools["deck_show"].meta)
        page = (await session.read_resource(ui_uri)).contents[0]
        check("the deck view is served as an MCP App", page.mime_type == "text/html;profile=mcp-app" and "ui/initialize" in page.text, page.mime_type)
        mana_uri = ((listed_tools["deck_analyze"].meta or {}).get("ui") or {}).get("resourceUri")
        check("deck_analyze points at a ui:// resource", mana_uri == "ui://knowledge-pool/mana-analysis.html", listed_tools["deck_analyze"].meta)
        mana_page = (await session.read_resource(mana_uri)).contents[0]
        check("the mana view is served as an MCP App", mana_page.mime_type == "text/html;profile=mcp-app" and "ui/initialize" in mana_page.text, mana_page.mime_type)
        analysed = await session.call_tool("deck_analyze", {"deck_id": deck["id"]})
        check("deck_analyze gives the view the mana data", analysed.structured_content["mana"]["land_count"] == 52 and analysed.structured_content["curve"]["buckets"]["1"] == 8, analysed.structured_content)
        check(
            "deck_analyze gives other clients Markdown tables",
            "| Cards | 0 | 8 | 0 |" in analysed.content[0].text and "| Red | 8 | 52 |" in analysed.content[0].text,
            analysed.content[0].text,
        )
        shown = await session.call_tool("deck_show", {"deck_id": deck["id"]})
        check("deck_show gives the view the deck data", shown.structured_content["main_total"] == 60, shown.structured_content)
        check("deck_show gives other clients a Markdown table", "| 52 | Mountain |" in shown.content[0].text, shown.content[0].text)
        # Real Scryfall tags vary by card and change over time, so this checks
        # the plumbing (a tagged card's actual tags land in both outputs),
        # not fixed tag names.
        bolt_card = next(c for c in shown.structured_content["cards"] if c["name"] == "Lightning Bolt")
        check("deck_show's structured content carries oracle tags per card", len(bolt_card["oracle_tags"]) > 0, bolt_card)
        guide_card = next(c for c in shown.structured_content["cards"] if c["name"] == "Goblin Guide")
        check(
            "deck_show's structured content carries stats and keywords per card",
            (guide_card["power"], guide_card["toughness"], guide_card["keywords"]) == ("2", "2", ["Haste"]),
            guide_card,
        )
        check(
            "deck_show's Markdown table has a P/T column and no tags",
            "| 4 | Goblin Guide | {R} | Creature — Goblin Scout | 2/2 |" in shown.content[0].text
            and not any(tag in shown.content[0].text for tag in bolt_card["oracle_tags"]),
            shown.content[0].text,
        )

        delver = await call(session, "get_card", oracle_id_or_name="Delver of Secrets")
        check(
            "get_card gives each face of a double-faced card with its own stats",
            [(f["name"], f["power"], f["toughness"]) for f in delver["faces"]]
            == [("Delver of Secrets", "1", "1"), ("Insectile Aberration", "3", "2")]
            and delver["keywords"] == ["Flying", "Transform"],
            delver,
        )
        jace = await call(session, "get_card", oracle_id_or_name="Jace, the Mind Sculptor")
        check("get_card gives a planeswalker's loyalty", jace["loyalty"] == "3", jace)

        search_uri = ((listed_tools["card_search"].meta or {}).get("ui") or {}).get("resourceUri")
        check("card_search points at a ui:// resource", search_uri == "ui://knowledge-pool/card-search.html", listed_tools["card_search"].meta)
        search_page = (await session.read_resource(search_uri)).contents[0]
        check(
            "the card search view is served as an MCP App that calls tools back through the host",
            search_page.mime_type == "text/html;profile=mcp-app"
            and all(m in search_page.text for m in ("ui/initialize", "tools/call", "deck_edit", "ui/update-model-context")),
            search_page.mime_type,
        )
        found = await session.call_tool("card_search", {"deck_id": deck["id"], "query": "lightning bolt", "limit": 5})
        bolt_hit = next(h for h in found.structured_content["hits"] if h["name"] == "Lightning Bolt")
        check("card_search says how many copies the deck holds", bolt_hit["in_deck"] == {"main": 4}, bolt_hit)
        check("card_search hits carry what the view shows", {"oracle_id", "name", "mana_cost", "type_line", "text"} <= set(bolt_hit), bolt_hit)
        check("card_search gives the view the deck's totals", found.structured_content["deck"]["main_total"] == 60, found.structured_content["deck"])
        check(
            "card_search gives other clients a Markdown table with an In deck column and a question",
            "| In deck |" in found.content[0].text and "| Lightning Bolt |" in found.content[0].text and "| 4 main |" in found.content[0].text
            and found.content[0].text.endswith("Which should I add, how many, and to main or sideboard?"),
            found.content[0].text,
        )
        shock = next(h for h in (await session.call_tool("card_search", {"deck_id": deck["id"], "query": "shock"})).structured_content["hits"] if h["name"] == "Shock")
        check("a card the deck does not hold has no in-deck counts", shock["in_deck"] == {}, shock)
        none_found = await session.call_tool("card_search", {"deck_id": deck["id"], "query": "zzqxv"})
        check("card_search with no matches says so", not none_found.is_error and none_found.structured_content["hits"] == [] and none_found.content[0].text.startswith("No cards match"), none_found.content)
        search_missing = await session.call_tool("card_search", {"deck_id": "nope", "query": "bolt"})
        check("card_search on an unknown deck is a tool error", search_missing.is_error and search_missing.content[0].text == "No deck with id nope.", search_missing.content)

        missing = await call(session, "deck_get", deck_id="nope")
        check("an unknown deck id says so", missing == {"error": "No deck with id nope.", "code": "no-such-deck"}, missing)
        no_import = await call(session, "deck_import", deck_id=deck["id"], format="mtgjson", text="{}")
        check("an export-only format says it cannot be imported", no_import.get("code") == "no-import", no_import)
        bad_format = await call(session, "deck_edit", deck_id=deck["id"], format="vintage")
        check("an unknown play format says so", bad_format.get("code") == "unknown-format", bad_format)
        shown_missing = await session.call_tool("deck_show", {"deck_id": "nope"})
        check("deck_show gives the reason as a tool error", shown_missing.is_error and shown_missing.content[0].text == "No deck with id nope.", shown_missing.content)
        analysed_missing = await session.call_tool("deck_analyze", {"deck_id": "nope"})
        check("deck_analyze gives the reason as a tool error", analysed_missing.is_error and analysed_missing.content[0].text == "No deck with id nope.", analysed_missing.content)

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
