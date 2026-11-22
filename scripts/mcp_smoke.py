"""End-to-end check of the MCP server over stdio, in local mode.

    jac run --no-serve scripts/mcp_smoke.py

Starts `jac run mcp_server.jac` as an MCP client would, on this worktree's
database (or `JAC_DB_URL`), and builds a deck through the tools. Then a
second MCP server process on the same database finds the deck: both run
every call as the local user.
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


async def call(session: ClientSession, tool: str, **args):
    result = await session.call_tool(tool, args)
    assert not result.is_error, (tool, result.content)
    if result.structured_content is not None:
        sc = result.structured_content
        return sc.get("result", sc) if isinstance(sc, dict) and set(sc) == {"result"} else sc
    return json.loads(result.content[0].text)


async def fails(session: ClientSession, tool: str, **args):
    """A tool that must fail: its structured content, which is `{error, code}`."""
    result = await session.call_tool(tool, args)
    assert result.is_error, (tool, result.content)
    assert set(result.structured_content) == {"error", "code"}, (tool, result.structured_content)
    return result.structured_content


def check(label: str, ok: bool, detail="") -> None:
    print(("PASS " if ok else "FAIL ") + label + (f": {detail}" if detail and not ok else ""))
    if not ok:
        raise SystemExit(1)


async def main() -> None:
    async with stdio_client(MCP_SERVER) as (read, write), ClientSession(read, write) as session:
        await session.initialize()
        tools = sorted(t.name for t in (await session.list_tools()).tools)
        print("tools:", ", ".join(tools))
        check("all the tools are listed", {
            "search_cards", "get_card", "resolve_names", "get_format_rules",
            "deck_create", "deck_get", "deck_edit", "deck_validate", "deck_analyze",
            "deck_export", "deck_import", "deck_show", "card_search", "deck_browse", "deck_copy",
        } <= set(tools))

        resolved = await call(session, "resolve_names", names=["Lightning Bolt", "Goblin Guide", "Lightening Bolt", "Flargle the Unreal", "Mountain"])
        check("exact names resolve", [e["name"] for e in resolved["exact"]] == ["Lightning Bolt", "Goblin Guide", "Mountain"], resolved)
        check("misspelling comes back as fuzzy with candidates", resolved["fuzzy"][0]["input"] == "Lightening Bolt" and resolved["fuzzy"][0]["candidates"][0]["name"] == "Lightning Bolt", resolved)
        check("invented card is unknown", resolved["unknown"] == ["Flargle the Unreal"], resolved)
        ids = {e["name"]: e["oracle_id"] for e in resolved["exact"]}

        rules = await call(session, "get_format_rules", format="modern")
        check("format rules", rules["min_main"] == 60 and rules["copy_limit"] == 4 and rules["sideboard_max"] == 15, rules)

        cmd_rules = await call(session, "get_format_rules", format="commander")
        check(
            "Commander rules say exactly 100, singleton",
            (cmd_rules["min_main"], cmd_rules["copy_limit"], cmd_rules["exact_size"]) == (100, 1, True)
            and any("Exactly 100 cards" in n for n in cmd_rules["notes"]),
            cmd_rules,
        )
        krenko = (await call(session, "resolve_names", names=["Krenko, Mob Boss"]))["exact"][0]["oracle_id"]
        cmd_deck = await call(session, "deck_create", name="MCP Krenko", format="commander", cards=[
            {"oracle_id": krenko, "count": 1, "zone": "commander", "reason": "commander"},
            {"oracle_id": ids["Mountain"], "count": 98, "zone": "main", "reason": "mana base"},
        ])
        cmd_verdict = await call(session, "deck_validate", deck_id=cmd_deck["id"])
        check(
            "deck_validate flags a 99-card Commander deck",
            cmd_verdict["legal"] is False and [v["rule"] for v in cmd_verdict["violations"]] == ["deck-size"],
            cmd_verdict,
        )

        check(
            "deck_validate returns Game Changers for a Commander deck",
            cmd_verdict["game_changers"]["count"] == 0 and cmd_verdict["game_changers"]["bracket_hint"] == "Bracket 1–2",
            cmd_verdict,
        )

        rhystic = (await call(session, "resolve_names", names=["Rhystic Study"]))["exact"][0]["oracle_id"]
        gc_deck = await call(session, "deck_create", name="MCP Krenko Study", format="commander", cards=[
            {"oracle_id": krenko, "count": 1, "zone": "commander", "reason": "commander"},
            {"oracle_id": rhystic, "count": 1, "zone": "main", "reason": "draw"},
            {"oracle_id": ids["Mountain"], "count": 97, "zone": "main", "reason": "mana base"},
        ])
        gc_shown = await session.call_tool("deck_show", {"deck_id": gc_deck["id"]})
        gc_text = gc_shown.content[0].text
        check(
            "deck_show's text names the Game Changers and has a Commander heading",
            "Game Changers: 1 (Rhystic Study)" in gc_text and "### Commander" in gc_text,
            gc_text,
        )

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
        check("deck_validate has no Game Changers for a Standard-style deck", verdict["game_changers"] is None, verdict)

        curve = deck["curve"]
        check("deck_edit's curve buckets the 4x Bolt and 4x Goblin Guide at mv 1", curve["buckets"]["1"] == 8, curve)
        check("deck_edit's curve excludes the 52 Mountain", curve["average_mv"] == 1.0, curve)

        deck = await call(session, "deck_edit", deck_id=deck["id"], format="standard")
        check("a format change still reports the curve", deck["curve"] == curve, deck)
        verdict = await call(session, "deck_validate", deck_id=deck["id"])
        check("switching to Standard makes it illegal, with reasons", not verdict["legal"] and {v["rule"] for v in verdict["violations"]} == {"not-legal"}, verdict)

        blank = await fails(session, "deck_edit", deck_id=deck["id"], name="  ")
        check("a blank name is refused with a message to show", blank.get("code") == "blank-name" and blank.get("error") == "A deck needs a name.", blank)
        deck = await call(session, "deck_edit", deck_id=deck["id"], name="  MCP Burn v2 ")
        check("deck_edit renames the deck, trimmed, with one history line", deck["name"] == "MCP Burn v2" and deck["history"][-1]["reason"] == "Renamed from MCP Burn to MCP Burn v2", deck)
        check("deck_list shows the new name", "MCP Burn v2" in [d["name"] for d in await call(session, "deck_list")])
        deck = await call(session, "deck_edit", deck_id=deck["id"], name="MCP Burn")

        deck = await call(session, "deck_edit", deck_id=deck["id"], changes=[
            {"oracle_id": ids["Lightning Bolt"], "count": 1, "zone": "main", "reason": "one more", "mode": "add"},
        ])
        check("an add change adds on top of the count", {c["name"]: c["count"] for c in deck["cards"] if c["zone"] == "main"}["Lightning Bolt"] == 5, deck)
        kept = await call(session, "deck_edit", deck_id=deck["id"], name="  ", changes=[
            {"oracle_id": ids["Lightning Bolt"], "count": 1, "zone": "main", "reason": "refused with its rename"},
        ])
        check("a refused rename refuses the whole edit", kept.get("code") == "blank-name", kept)
        deck = await call(session, "deck_get", deck_id=deck["id"])
        check("a refused rename leaves the cards unchanged", {c["name"]: c["count"] for c in deck["cards"] if c["zone"] == "main"}["Lightning Bolt"] == 5, deck)
        deck = await call(session, "deck_edit", deck_id=deck["id"], changes=[
            {"oracle_id": ids["Lightning Bolt"], "count": 4, "zone": "main", "reason": "back to four"},
        ])

        arena = await session.call_tool("deck_export", {"deck_id": deck["id"]})
        check("deck_export gives a client without MCP Apps no structured content", arena.structured_content is None, arena.structured_content)
        check(
            "deck_export defaults to MTGA/MTGO, its text giving the list in a code block and saying what it drops",
            arena.content[0].text.startswith("Exported MCP Burn as MTGA/MTGO.")
            and "```\nDeck\n" in arena.content[0].text and "drops other zones, roles, tags, locks and reasons" in arena.content[0].text,
            arena.content[0].text,
        )
        lossless = await session.call_tool("deck_export", {"deck_id": deck["id"], "format": "mtgdeck1"})
        lossless_text = lossless.content[0].text
        check("a lossless export's text starts with a short summary", lossless_text.startswith("Exported MCP Burn as mtgdeck/1 (lossless,"), lossless_text[:200])
        exported = lossless_text.split("```json\n", 1)[1].rsplit("\n```", 1)[0]
        check("a lossless export's text carries the whole mtgdeck/1 document", json.loads(exported)["schema"] == "mtgdeck/1", lossless_text[:200])
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

        reimported = await call(session, "deck_import", deck_id=deck["id"], format="mtgdeck1", text=exported)
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
        # Some clients (Claude Code among them) give the model the structured
        # content in place of the text, so a client without MCP Apps gets none:
        # the Markdown is the whole answer.
        analysed = await session.call_tool("deck_analyze", {"deck_id": deck["id"]})
        check("deck_analyze gives a client without MCP Apps no structured content", analysed.structured_content is None, analysed.structured_content)
        check(
            "deck_analyze gives other clients Markdown tables",
            "| Cards | 0 | 8 | 0 |" in analysed.content[0].text and "| Red | 8 | 52 |" in analysed.content[0].text,
            analysed.content[0].text,
        )
        shown = await session.call_tool("deck_show", {"deck_id": deck["id"]})
        check("deck_show gives a client without MCP Apps no structured content", shown.structured_content is None, shown.structured_content)
        check("deck_show gives other clients a Markdown table", "| 52 | Mountain |" in shown.content[0].text, shown.content[0].text)
        check(
            "deck_show's Markdown table has a P/T column",
            "| 4 | Goblin Guide | {R} | Creature — Goblin Scout | 2/2 |" in shown.content[0].text,
            shown.content[0].text,
        )
        shown_markdown = shown.content[0].text

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
        check("card_search gives a client without MCP Apps no structured content", found.structured_content is None, found.structured_content)
        check(
            "card_search gives other clients a Markdown table with an In deck column and a question",
            "| In deck |" in found.content[0].text and "| Lightning Bolt |" in found.content[0].text and "| 4 main |" in found.content[0].text
            and found.content[0].text.endswith("Which should I add, how many, and to main or sideboard?"),
            found.content[0].text,
        )
        none_found = await session.call_tool("card_search", {"deck_id": deck["id"], "query": "zzqxv"})
        check("card_search with no matches says so", not none_found.is_error and none_found.content[0].text.startswith("No cards match"), none_found.content)
        search_missing = await session.call_tool("card_search", {"deck_id": "nope", "query": "bolt"})
        check("card_search on an unknown deck is a tool error", search_missing.is_error and search_missing.content[0].text == "No deck with id nope.", search_missing.content)

        missing = await fails(session, "deck_get", deck_id="nope")
        check("an unknown deck id says so", missing == {"error": "No deck with id nope.", "code": "no-such-deck"}, missing)
        no_cards = await call(session, "deck_import", deck_id=deck["id"], format="mtgjson", text="{}")
        check("an MTGJSON deck with no cards imports nothing", no_cards.get("unresolved") == ["Nothing to import: no cards found."], no_cards)
        bad_format = await fails(session, "deck_edit", deck_id=deck["id"], format="vintage")
        check("an unknown play format says so", bad_format.get("code") == "unknown-format", bad_format)
        shown_missing = await session.call_tool("deck_show", {"deck_id": "nope"})
        check("deck_show gives the reason as a tool error", shown_missing.is_error and shown_missing.content[0].text == "No deck with id nope.", shown_missing.content)
        analysed_missing = await session.call_tool("deck_analyze", {"deck_id": "nope"})
        check("deck_analyze gives the reason as a tool error", analysed_missing.is_error and analysed_missing.content[0].text == "No deck with id nope.", analysed_missing.content)

        listed = await call(session, "deck_list")
        check("deck_list lists the deck", "MCP Burn" in [d["name"] for d in listed], listed)
        browsed = await call(session, "deck_browse")
        check("deck_browse lists no deck of the local user's own", "MCP Burn" not in [d["name"] for d in browsed], browsed)
        copied = await call(session, "deck_copy", deck_id=deck["id"])
        check("deck_copy makes the caller's own '<name> (copy)'", copied["name"] == "MCP Burn (copy)" and copied["id"] != deck["id"], copied)
        copy_missing = await fails(session, "deck_copy", deck_id="nope")
        check("deck_copy gives an unknown deck as an error with its code", copy_missing.get("code") == "no-such-deck", copy_missing)
        listed = await call(session, "deck_list")
        check("deck_list lists the copy after", "MCP Burn (copy)" in [d["name"] for d in listed], listed)

    # A client that renders MCP Apps already shows the view, so the model gets a
    # short brief instead of the full Markdown (otherwise it repeats the view).
    # A second MCP server process on the same database, as the same local user.
    apps_ext = {"io.modelcontextprotocol/ui": {"mimeTypes": ["text/html;profile=mcp-app"]}}
    async with stdio_client(MCP_SERVER) as (read, write), ClientSession(read, write, extensions=apps_ext) as session:
        await session.initialize()
        listed = await call(session, "deck_list")
        check("a second MCP server process lists the local user's deck", "MCP Burn" in [d["name"] for d in listed], listed)
        shown = await session.call_tool("deck_show", {"deck_id": deck["id"]})
        check(
            "deck_show gives an Apps client a brief, not the table",
            shown.content[0].text.startswith("Shown to the user as an expandable deck list: MCP Burn")
            and "| Mountain |" not in shown.content[0].text,
            shown.content[0].text,
        )
        check("deck_show gives the view the deck data", shown.structured_content["main_total"] == 60, shown.structured_content)
        # Real Scryfall tags vary by card and change over time, so this checks
        # the plumbing (a tagged card's actual tags reach the view and stay out
        # of the Markdown), not fixed tag names.
        bolt_card = next(c for c in shown.structured_content["cards"] if c["name"] == "Lightning Bolt")
        check("deck_show's structured content carries oracle tags per card", len(bolt_card["oracle_tags"]) > 0, bolt_card)
        check("deck_show's Markdown table has no tags", not any(tag in shown_markdown for tag in bolt_card["oracle_tags"]), shown_markdown)
        guide_card = next(c for c in shown.structured_content["cards"] if c["name"] == "Goblin Guide")
        check(
            "deck_show's structured content carries stats and keywords per card",
            (guide_card["power"], guide_card["toughness"], guide_card["keywords"]) == ("2", "2", ["Haste"]),
            guide_card,
        )

        analysed = await session.call_tool("deck_analyze", {"deck_id": deck["id"]})
        check(
            "deck_analyze gives an Apps client the numbers on one line, not tables",
            "52 lands" in analysed.content[0].text and "Red 8 pips, 52 sources" in analysed.content[0].text
            and "|" not in analysed.content[0].text,
            analysed.content[0].text,
        )
        analysis = analysed.structured_content
        check(
            "deck_analyze gives the view the mana base",
            analysis["mana"]["land_count"] == 52 and analysis["mana"]["pips"]["R"] == 8 and analysis["mana"]["sources"]["R"] == 52,
            analysis,
        )
        check("deck_analyze gives the view the same curve as deck_edit", analysis["curve"] == curve, analysis)
        check(
            "deck_analyze is the deck's analysis only, not its cards",
            set(analysis) == {"id", "name", "format", "main_total", "mana", "curve"}
            and analysis["name"] == "MCP Burn" and analysis["main_total"] == 60,
            analysis,
        )

        found = await session.call_tool("card_search", {"deck_id": deck["id"], "query": "lightning bolt", "limit": 5})
        check(
            "card_search gives an Apps client the hits with oracle ids, not a table",
            found.content[0].text.startswith("Shown to the user as a search panel")
            and "Lightning Bolt (" in found.content[0].text and "4 main in deck" in found.content[0].text
            and "|" not in found.content[0].text,
            found.content[0].text,
        )
        bolt_hit = next(h for h in found.structured_content["hits"] if h["name"] == "Lightning Bolt")
        check("card_search says how many copies the deck holds", bolt_hit["in_deck"] == {"main": 4}, bolt_hit)
        check("card_search hits carry what the view shows", {"oracle_id", "name", "mana_cost", "type_line", "text"} <= set(bolt_hit), bolt_hit)
        check("card_search gives the view the deck's totals", found.structured_content["deck"]["main_total"] == 60, found.structured_content["deck"])
        shock = next(h for h in (await session.call_tool("card_search", {"deck_id": deck["id"], "query": "shock"})).structured_content["hits"] if h["name"] == "Shock")
        check("a card the deck does not hold has no in-deck counts", shock["in_deck"] == {}, shock)
        none_found = await session.call_tool("card_search", {"deck_id": deck["id"], "query": "zzqxv"})
        check("card_search with no matches gives the view no hits", none_found.structured_content["hits"] == [], none_found.structured_content)

        arena = await session.call_tool("deck_export", {"deck_id": deck["id"]})
        check(
            "deck_export tells an Apps client not to paste the export, and still carries it",
            arena.content[0].text.startswith("Shown to the user in the export view")
            and "4 Lightning Bolt" in arena.content[0].text,
            arena.content[0].text,
        )
        check("deck_export defaults to MTGA/MTGO (arena)", arena.structured_content["format"] == "arena" and arena.structured_content["content"].startswith("Deck\n"), arena.structured_content)
        check("deck_export names the deck for the view", arena.structured_content["name"] == "MCP Burn" and arena.structured_content["deck_id"] == deck["id"], arena.structured_content)
        check(
            "deck_export lists every format with its lossless flag",
            {f["key"]: f["lossless"] for f in arena.structured_content["formats"]}
            == {"arena": False, "moxfield": False, "text": False, "mtgdeck1": True, "mtgjson": True},
            arena.structured_content["formats"],
        )
        lossless = await session.call_tool("deck_export", {"deck_id": deck["id"], "format": "mtgdeck1"})
        check("a lossless export's text carries the view's whole JSON", lossless.structured_content["content"] in lossless.content[0].text, lossless.content[0].text[:200])

    print("all checks passed")


anyio.run(main)
