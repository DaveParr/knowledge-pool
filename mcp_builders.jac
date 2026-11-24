"""The MCP tools' text, built from data alone: the Markdown a client without
MCP Apps reads, and the brief a client with them gives the model. Every function
here is pure (no graph, catalogue or server), so it is tested with plain data in
`tests/mcp_builders_tests.jac`. The tools that call them are in `mcp_tools.jac`."""

import json;
import from zones { ZONES, ZONE_TITLES }
import from deckformats { export_format_choices }
import from json_object { JsonObject }

glob COLOUR_NAMES: dict[str, str] = {"W": "White", "U": "Blue", "B": "Black", "R": "Red", "G": "Green"},
     LOSSY_DROPS: str = "keeps card names and counts for the main deck and sideboard only. It drops other zones, roles, tags, locks and reasons.";

"""What the model gets when the user already sees the deck view: the deck's
shape and legality, and a note not to list the cards again."""
def deck_brief(view: JsonObject) -> str {
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
def game_changers_note(view: JsonObject) -> str {
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
def deck_markdown(view: JsonObject) -> str {
    lines = [
        f"## {view['name']}",
        f"{view['format']}, {view['main_total']} main, {view['sideboard_total']} sideboard. "
        + ("Legal." if view["legal"] else "Not legal: " + "; ".join(v["message"] for v in view["violations"]))
    ];
    note = game_changers_note(view).strip();
    if note {
        lines.append(note);
    }
    for zone in ZONES {
        title = ZONE_TITLES[zone];
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
def power_toughness(card: JsonObject) -> str {
    if not card["power"] and not card["toughness"] {
        return "";
    }
    return f"{card['power']}/{card['toughness']}";
}

"""What the model gets when the user already sees the mana chart: the numbers
on one line, so it can comment on them, and a note not to redraw the chart."""
def mana_brief(analysis: JsonObject) -> str {
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
def mana_markdown(analysis: JsonObject) -> str {
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

"""What the model gets when the user already sees the search panel: the hits
on one line with oracle ids (so it can still add one when asked in chat), and
a note not to list them again."""
def search_brief(result: JsonObject) -> str {
    hits = result["hits"] as list[JsonObject];
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

"""One Markdown table cell: no pipes or line breaks."""
def md_cell(value: str) -> str {
    return value.replace("|", "\\|").replace("\n", " ");
}

"""Search hits as a Markdown table with an In deck column, for clients that do not
render MCP Apps (and for the model). The oracle ids are there so the model can pass
them straight to deck_edit."""
def search_markdown(result: JsonObject) -> str {
    hits = result["hits"] as list[JsonObject];
    query = result["query"] as str;
    if not hits {
        return f"No cards match \"{query}\". Every word must match the start of a word in the name, type or rules text.";
    }
    deck_name = (result["deck"] as JsonObject)["name"] as str;
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

"""The lead-in the model gets when the user already sees the export view. The
export text still follows it, so the model can answer questions about it."""
def export_brief -> str {
    return (
        "Shown to the user in the export view, with a button per format, Copy and Download. "
        + "The export below is for your reference only: do not paste it into the chat unless the user asks "
        + "to see it here.\n\n"
    );
}

"""The export as chat text, for the model and for clients that do not render MCP
Apps. A lossy list goes in a code block with what it drops. A lossless JSON export
leads with a short summary and a hint not to paste it unprompted, then the full
JSON, so a client without the view (Claude Code) can still show or save it."""
def export_text(result: JsonObject) -> str {
    label = result["format"];
    lossless = False;
    for f in export_format_choices() {
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
