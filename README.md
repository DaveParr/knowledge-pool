# knowledge-pool

Personal knowledge/working repo, set up with [Matt Pocock's Claude Code skills](https://github.com/mattpocock/skills) for use with Claude Code.

## Skills

The 25 skills from the `engineering` and `productivity` buckets of [mattpocock/skills](https://github.com/mattpocock/skills) (commit `5b15a47`) are copied into [.claude/skills/](.claude/skills/) as editable project skills. See that repo's `README.md` for what each skill does.

Attribution: these skill files are copied from mattpocock/skills, MIT licensed by Matt Pocock — see [.claude/skills/LICENSE-mattpocock-skills](.claude/skills/LICENSE-mattpocock-skills).

## Setup

Run `/setup-matt-pocock-skills` once in a Claude Code session in this repo to configure issue tracker, triage labels, and docs location.

## MTG deckbuilder (Jac)

A local Magic: The Gathering deckbuilder written in [Jac](https://www.jaseci.org/). The server side is Jac walkers over a persistent graph; the UI is a Jac client app served by the same process.

### Setup

Needs [uv](https://docs.astral.sh/uv/) and Node.js (the Jac client build uses npm packages). Jac is pinned in `pyproject.toml` because it is pre-1.0 and changes between minor versions.

Dependencies are pinned to exact versions. Python packages are locked by `uv.lock`; `uv sync --locked` fails instead of rewriting the lockfile if it is out of date with `pyproject.toml`. Change Python dependencies with `uv add`/`uv remove`, not `jac add`/`jac install`, which install into a separate `.jac/venv` and ignore `uv.lock`. The npm packages for the client are pinned to exact versions in `jac.toml`; Jac has no npm lockfile it reuses, so their own dependencies are not locked.

```bash
uv sync --locked
uv run python -m catalog.ingest
```

The ingest downloads MTGJSON's `AtomicCards.json.xz` (about 26 MB) and builds `data/catalog.sqlite`: one row per oracle card (cost, type line, rules text, power/toughness, loyalty, defence, keywords, legalities, and each face of a double-faced, split or adventure card) plus an FTS5 search index, with the MTGJSON version and build date in its `meta` table. It takes a few seconds. Pass `--source FILE` to build from a file you already have. Run it again to pick up a newer MTGJSON build. Run it again after pulling new code, too: a code change can add columns or tables to the catalogue, and the server (`jac start` and the MCP server) refuses to start against a catalogue built by older code, with a message that names this command.

In a new worktree (or after deleting `.jac/data`), fill the graph with real decks to look at and test against. A worktree needs a catalogue first; rather than re-run the ingest, point `KP_CATALOG` at the main checkout's:

```bash
export KP_CATALOG=/path/to/main/checkout/data/catalog.sqlite   # or: uv run python -m catalog.ingest
uv run jac run seed.jac
```

It adds one random MTGJSON precon for each format (a Challenger Deck for Standard, a Pioneer Challenger Deck, a Modern Event Deck and a Commander Deck) to the shared graph the web app and MCP server use, and prints one line per format: the deck, its type and release date, whether it is legal, and any unresolved cards. For Standard, Pioneer and Modern it tries up to 3 precons and keeps the first legal one, else the last tried (old Challenger Decks have rotated out of Standard). Commander precons show as illegal Standard decks until there is a Commander format. A precon already in the graph is never picked again, so run it again for more decks. The seed is printed every run; `--seed N` repeats a set of picks on a fresh graph, `--format X` (repeatable) limits the formats, and `--from-dir DIR` reads `DeckList.json` and deck files from DIR instead of mtgjson.com. Downloads are cached in `data/mtgjson/decks/`. Stop `jac start` and the MCP server first: like the MCP server, it refuses to run while `KP_PORT` (default 8000) is taken.

### Run

```bash
uv run jac start main.jac
```

Open http://localhost:8000. The Decks view lists your decks and creates new ones. Open a deck to search cards by name or rules text, add them to the main deck or sideboard, change counts and remove them. Each card is one compact line (count, name, cost, type, and power/toughness for creatures); click it to expand its rules text (face by face for double-faced and split cards), loyalty or defence, keywords, this deck's notes for it, and its Scryfall tags. Each zone has Expand all and Collapse all. Each deck has a format (Standard, Pioneer or Modern), and the deck view shows straight away whether it is legal and lists each rule it breaks: at least 60 main-deck cards, at most 15 in the sideboard, at most 4 copies of a card across both (basic lands and "any number" cards are exempt, and cards like Seven Dwarves use their own limit), and every card legal in the format according to MTGJSON. Legality is worked out on every view and edit; it is never stored. Decks are stored in `.jac/data` and survive a restart; delete that folder to start fresh.

The full catalogue stays in SQLite. A `Card` node is added to the graph the first time a deck uses that card, because saving all 35,000 cards as graph nodes took more than 15 minutes. A `Card` node keeps a copy of the card's catalogue data, so after re-running the ingest, refresh the copies once with the app running: `curl -X POST http://localhost:8000/walker/RefreshCards`. Until then, cards already in a deck show their old data (for example, no power/toughness after the upgrade that added it).

### Use with Claude (MCP)

`mcp_server.jac` is a local stdio MCP server for Claude Code or Claude Desktop. Register it once from the repo folder:

```bash
claude mcp add knowledge-pool -- uv run --directory "$PWD" jac run mcp_server.jac
```

Then ask Claude to build or change a deck, for example "build a Modern mono-red burn deck around Lightning Bolt and Goblin Guide". The tools are `search_cards`, `get_card`, `resolve_names`, `get_format_rules`, `deck_list`, `deck_create`, `deck_get`, `deck_edit`, `deck_validate`, `deck_analyze`, `deck_export`, `deck_import`, `deck_show` and `card_search`. `deck_analyze` reports a deck's mana base (land count, plus coloured pips and coloured sources for each colour) and its mana curve (non-land card count by mana value, plus the average), main deck only. `deck_get` and `deck_edit` return the same analysis alongside the cards. `card_search` searches the catalogue for one deck: each hit shows how many copies the deck already holds. Clients that support MCP Apps (Claude Desktop, claude.ai) show `deck_show` as a list where each card expands to its details, `deck_analyze` as a mana curve and pips-vs-sources chart, and `card_search` as a search panel whose **+ Main** / **+ Side** buttons add cards with `deck_edit` and tell Claude what changed. Others, such as Claude Code, get the same as Markdown (the deck as a compact table with a P/T column). Where the view is shown, Claude itself gets only a one-line summary (and, for a search, the hits with their oracle ids), so it doesn't repeat what the user can already see; it calls `deck_get` when it needs the cards. Ask about a card and Claude calls `get_card`, which returns its rules text, stats, keywords and each face. Card names have to go through `resolve_names`, which splits them into exact, fuzzy and unknown, so an invented card can't get into a deck. Every `deck_edit` change needs a reason, and the reasons are kept in the deck's history. No tool calls a model.

`deck_export` defaults to MTGA/MTGO (`arena`); the other formats are `moxfield`, `text` (both lossy, like `arena`), `mtgdeck1` and `mtgjson` (lossless JSON). In clients that render MCP Apps (Claude Desktop, claude.ai) the export shows in a view (`ui/deck_export.html`) with a button per format, **Copy** and **Download**; changing format there calls `deck_export` again through the host. Other clients, such as Claude Code, get the export as text: a lossy list in a code block, or a short summary followed by the full JSON for a lossless format. `deck_import` and the app's **Import list** read the same formats; `mtgjson` also takes a deck file from MTGJSON (`https://mtgjson.com/api/v5/decks/`), such as a Commander precon, and lists any tokens, planes or schemes it skips.

The MCP server also serves the web app at http://localhost:8000 while Claude is connected, so decks made in either place show up in the other straight away. Stop `jac start` first: two Jac processes writing the same saved graph overwrite each other's decks, so the MCP server refuses to start while the port is taken. Set `KP_PORT` to use a different port, or `KP_WEB=0` to skip the web app.

`uv run python scripts/mcp_smoke.py` runs a full stdio session against your local data as a check.

### QA

[docs/qa-mvp.md](docs/qa-mvp.md) walks through running the MVP locally and checking each P0 issue by hand. [docs/qa-deck-import-export.md](docs/qa-deck-import-export.md) does the same for deck import and export (#37).

### Test

```bash
uv run jac test        # walker tests in tests/*_tests.jac
uv run pytest tests    # ingest, search, REST, legality and MCP tests
```

`tests/fixtures/legality_decks.json` holds 27 known legal and illegal decks that the validator is tested against. Tests build their catalogue from `tests/fixtures/atomic_small.json`, 35 real cards taken from MTGJSON (legalities as of 2 Nov 2026). Type-check with `uv run jac check *.jac`. Run `jac guide` for Jac's own reference guides (see `AGENTS.md`).

### Layout

- `main.jac` entry point, joins server and client
- `catalog/` Python ingest (`ingest.py`) and search (`store.py`) over `data/catalog.sqlite`
- `cards.sv.jac` the `Card` node and the `search_cards` endpoint
- schemas/mtgdeck-1.schema.json the published mtgdeck/1 deck document schema
- `deckformats/` the deck import/export format strategies (mtgdeck/1, MTGJSON Deck JSON, plain/Arena/Moxfield text)
- `decks.sv.jac` the `Deck` node, the `Holds` edge, the deck walkers, `card_lines` and `deck_view`
- `deck_io.sv.jac` the `DeckExport`, `DeckImport` and `CreateDeckFromList` walkers
- `export_panel.cl.jac` the per-deck Export panel (format, preview, copy, download)
- `mana_panel.cl.jac`, `card_search.cl.jac` (`AddCards`) the deck page's mana and search sections
- `mana_cost.cl.jac` mana costs as symbol pills (the MCP views draw the same)
- `global.css` app-wide style tokens, shared with the MCP Apps views in `ui/`
- `legality.sv.jac` `Format` nodes and the deck-construction rules
- `mcp_server.jac` the MCP server (and the web app, in the same process)
- `shared_graph.jac` runs walkers on the shared (guest) root from outside the web app, for the MCP server and the seed script
- `seed.jac`, `catalog/precons.py` the seed script: one random MTGJSON precon per format
- `ui/` the MCP Apps views: `deck_table.html` (`deck_show`), `mana_analysis.html` (`deck_analyze`), `card_search.html` (`card_search`) and `deck_export.html` (`deck_export`); `ui/mockups/` holds the signed-off static mockups
- `scripts/mcp_smoke.py` an MCP client session that checks the tools end to end
- `frontend.cl.jac`, `frontend.impl.jac` the Decks view
- `deck_detail.cl.jac`, `deck_detail.impl.jac` one deck: search, add, change, remove
- `tests/` walker and REST tests

### Spikes

- [S02: Jac go/no-go](docs/spikes/s02-jac-go-no-go.md): go, with the catalogue graph held in memory. Code in `spike/`.
