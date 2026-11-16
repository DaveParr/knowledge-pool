# knowledge-pool

Personal knowledge/working repo, set up with [Matt Pocock's Claude Code skills](https://github.com/mattpocock/skills) for use with Claude Code.

## Skills

The 25 skills from the `engineering` and `productivity` buckets of [mattpocock/skills](https://github.com/mattpocock/skills) (commit `5b15a47`) are copied into [.claude/skills/](.claude/skills/) as editable project skills. See that repo's `README.md` for what each skill does.

Attribution: these skill files are copied from mattpocock/skills, MIT licensed by Matt Pocock — see [.claude/skills/LICENSE-mattpocock-skills](.claude/skills/LICENSE-mattpocock-skills).

## Setup

Run `/setup-matt-pocock-skills` once in a Claude Code session in this repo to configure issue tracker, triage labels, and docs location.

## MTG deckbuilder (Jac)

A local Magic: The Gathering deckbuilder written in [Jac](https://www.jaseci.org/). The server side is Jac walkers over a persistent graph, stored in Postgres; the UI is a Jac client app served by the same process.

### Setup

Needs the `jac` binary, at the one version `jac.toml` pins (`[project] jac-version`), because Jac is pre-1.0 and changes between releases. `scripts/install_jac.sh` installs that version as `~/.local/bin/jac`, checking its checksum; CI runs the same script. Moving the pin is a pull request that changes nothing else, merged when `jac x check` passes.

Jac brings its own Python and Postgres. Python and npm packages are listed in `jac.toml` and locked in `jac.lock`; `jac install --dev` installs them into `.jac/venv`, and `jac install --dev --frozen` (what CI runs) fails if the lockfile is out of date. Change them with `jac install --pypi <pkg>` / `jac remove --pypi <pkg>`.

```bash
scripts/install_jac.sh
jac install --dev
jac x catalogue
```

The ingest downloads MTGJSON's `AtomicCards.json.xz` (about 26 MB) and builds `data/catalog.sqlite`: one row per oracle card (cost, type line, rules text, power/toughness, loyalty, defence, keywords, legalities, and each face of a double-faced, split or adventure card) plus an FTS5 search index, with the MTGJSON version and build date in its `meta` table. It takes a few seconds. Pass `--source FILE` to build from a file you already have. Run it again to pick up a newer MTGJSON build. Run it again after pulling new code, too: a code change can add columns or tables to the catalogue, and the web app and the MCP server refuse to start against a catalogue built by older code, with a message that names this command.

The ingest keeps its downloads in a cache shared by every worktree, `${XDG_CACHE_HOME:-~/.cache}/knowledge-pool/` (override with `KP_CACHE`), and downloads again after 7 days (`--max-age-days`). In a new worktree, `jac x up` or `jac x catalogue` builds `data/catalog.sqlite` from that cache, offline when it is warm. Both run `python -m catalog.ingest --if-stale`, which rebuilds only when the catalogue is missing or its schema is out of date for the code. It does not refresh a current catalogue from newer MTGJSON data; plain `.jac/venv/bin/python -m catalog.ingest` does that (it also takes `--source FILE`, which `jac x` cannot pass on).

In a new worktree, fill the graph with real decks to look at and test against:

```bash
jac run --no-serve seed.jac
```

It adds one random MTGJSON precon for each format (a Challenger Deck for Standard, a Pioneer Challenger Deck, a Modern Event Deck and a Commander Deck) to the local user's decks (the decks the MCP server shows in local mode), and prints one line per format: the deck, its type and release date, whether it is legal, and any unresolved cards. For Standard, Pioneer and Modern it tries up to 3 precons and keeps the first legal one, else the last tried (old Challenger Decks have rotated out of Standard). A precon already in the graph is never picked again, so run it again for more decks. The seed is printed every run; `--seed N` repeats a set of picks on a fresh graph, `--format X` (repeatable) limits the formats, and `--from-dir DIR` reads `DeckList.json` and deck files from DIR instead of mtgjson.com. Downloads are cached in `data/mtgjson/decks/`. The MCP server may keep running: decks the seed adds show up in it at once. Until the web page's deck calls go through the runner too, the web page shows the guest's decks, not these.

### Run

```bash
jac x up
```

This runs the **front door** (`front_door.jac`, started by `mcp_server.jac`) on a port chosen for the worktree, and prints `web:`, `mcp:` and `log:` lines. The front door is the only listener: it answers `/mcp`, runs the web page's deck calls itself as the local user, and hands the page and its static files out from Jac's server, which it starts as a child on `127.0.0.1` (the next port up). Every other path, Jac's `/docs`, `/graph`, `/admin` and `/user/*` among them, answers 404; `/healthz` answers `ok`. If the child stops, the front door exits. Open the `web:` URL (the examples below say http://localhost:8000, the port a bare `jac run` used to use). `jac x status` reprints them and `jac x down` stops both. `jac x` lists every repo command; it cannot pass arguments, so call `scripts/dev.sh` directly for `KP_DEV_PORT` and similar overrides.

Open the `web:` URL. The Decks view lists your decks and creates new ones. Open a deck to search cards by name or rules text, add them to the main deck or sideboard, change counts and remove them. Each card is one compact line (count, name, cost, type, and power/toughness for creatures); click it to expand its rules text (face by face for double-faced and split cards), loyalty or defence, keywords, this deck's notes for it, and its Scryfall tags. Each zone has Expand all and Collapse all. Each deck has a format (`get_format_rules` lists them), and the deck view shows straight away whether it is legal and lists each rule it breaks. For the 60-card formats that is at least 60 main-deck cards, at most 15 in the sideboard, at most 4 copies of a card across both (basic lands and "any number" cards are exempt, and cards like Seven Dwarves use their own limit), and every card legal in the format according to MTGJSON. Legality is worked out on every view and edit; it is never stored. Decks are stored in Postgres and survive a restart. Locally that is the Postgres server Jac starts itself, shared by the whole machine, with one database per worktree (keyed to the worktree's path), so each worktree has its own decks with no setting. `jac db status` names this worktree's database; `jac db drop <name> -y` (with `jac x down` first) starts fresh. Set `JAC_DB_URL` to use another Postgres server instead.

The full catalogue stays in SQLite. A `Card` node is added to the graph the first time a deck uses that card, because saving all 35,000 cards as graph nodes took more than 15 minutes. A `Card` node keeps a copy of the card's catalogue data, so after re-running the ingest the copies are refreshed by themselves: the MCP server does it at start, as the guest, when the catalogue is a different build from the one the copies were last refreshed against, and skips it otherwise. Restart the app after an ingest. Until then, cards already in a deck show their old data (for example, no power/toughness after the upgrade that added it), and commanders in an existing graph show as ineligible.

### Use with Claude (MCP)

`mcp_server.jac` is a local stdio MCP server for Claude Code or Claude Desktop. Register it once from the repo folder:

```bash
claude mcp add knowledge-pool -- jac run --no-serve "$PWD/mcp_server.jac"
```

`jac x up` prints the equivalent HTTP registration for its worktree (`claude mcp add --transport http knowledge-pool-<slug> http://127.0.0.1:<port>/mcp`), which suits a worktree. Then ask Claude to build or change a deck, for example "build a Modern mono-red burn deck around Lightning Bolt and Goblin Guide". The tools are `search_cards`, `get_card`, `resolve_names`, `get_format_rules`, `deck_list`, `deck_create`, `deck_get`, `deck_edit`, `deck_validate`, `deck_analyze`, `deck_export`, `deck_import`, `deck_show` and `card_search`. `deck_analyze` reports a deck's mana base (land count, plus coloured pips and coloured sources for each colour) and its mana curve (non-land card count by mana value, plus the average), main deck only. `deck_get` and `deck_edit` return the same analysis alongside the cards. `card_search` searches the catalogue for one deck: each hit shows how many copies the deck already holds. Clients that support MCP Apps (Claude Desktop, claude.ai) show `deck_show` as a list where each card expands to its details, `deck_analyze` as a mana curve and pips-vs-sources chart, and `card_search` as a search panel whose **+ Main** / **+ Side** buttons add cards with `deck_edit` and tell Claude what changed. Others, such as Claude Code, get the same as Markdown (the deck as a compact table with a P/T column). Where the view is shown, Claude itself gets only a one-line summary (and, for a search, the hits with their oracle ids), so it doesn't repeat what the user can already see; it calls `deck_get` when it needs the cards. Ask about a card and Claude calls `get_card`, which returns its rules text, stats, keywords and each face. Card names have to go through `resolve_names`, which splits them into exact, fuzzy and unknown, so an invented card can't get into a deck. Every `deck_edit` change needs a reason, and the reasons are kept in the deck's history. No tool calls a model.

`deck_export` defaults to MTGA/MTGO (`arena`); the other formats are `moxfield`, `text` (both lossy, like `arena`), `mtgdeck1` and `mtgjson` (lossless JSON). In clients that render MCP Apps (Claude Desktop, claude.ai) the export shows in a view (`ui/deck_export.html`) with a button per format, **Copy** and **Download**; changing format there calls `deck_export` again through the host. Other clients, such as Claude Code, get the export as text: a lossy list in a code block, or a short summary followed by the full JSON for a lossless format. `deck_import` and the app's **Import list** read the same formats; `mtgjson` also takes a deck file from MTGJSON (`https://mtgjson.com/api/v5/decks/`), such as a Commander precon, and lists any tokens, planes or schemes it skips.

The MCP tools and the web page's deck calls run through the same runner as the local user, so decks made in either place show up in the other straight away. Another process on the same database (a second front door, the seed script) can win a write race; the runner rolls the call back and re-runs it, and answers `try-again` if it still conflicts.

`jac run --no-serve scripts/mcp_smoke.py` starts the web app and runs a full stdio session against your local data as a check.

### QA

[docs/qa-mvp.md](docs/qa-mvp.md) walks through running the MVP locally and checking each P0 issue by hand. [docs/qa-deck-import-export.md](docs/qa-deck-import-export.md) does the same for deck import and export (#37).

### Test

```bash
jac x check     # type-check, walker tests (tests/*_tests.jac) and pytest, then drop databases whose folder is gone: what CI runs
jac x test-ui   # browser smoke test of the web app; skips without a browser (CI sets KP_REQUIRE_BROWSER=1)
```

`tests/fixtures/legality_decks.json` holds 27 known legal and illegal decks that the validator is tested against, and `tests/fixtures/commander_decks.json` holds known Commander decks, including real MTGJSON precons in `tests/fixtures/mtgjson_decks/` (trimmed, MIT). Tests build their catalogue from `tests/fixtures/atomic_small.json`, real cards taken from MTGJSON (legalities as of 2 Nov 2026); `scripts/fixture_cards.py` adds cards to it. `jac x check` also type-checks. Tests that start Jac processes get a database of their own from the `jac_db_url` fixture (`tests/conftest.py`), on a Postgres server the test run starts on 127.0.0.1 from Jac's own embedded distribution; in-process tests use `JacTestClient.from_file(..., base_path=tmp_path)`, which gives each its own database. Run `jac guide` for Jac's own reference guides (see `AGENTS.md`).

### Container image

The `Dockerfile` builds the hosted image on `jaseci/jaclang:<the version jac.toml pins>`: the app, the web bundle and the card catalogue, started in hosted mode (`KP_MODE=hosted`, listening on `$PORT`). The build never starts a Postgres (each Jac step is given an address nothing listens on); `catalogue_date.txt` is copied before the catalogue step, so changing it rebuilds the catalogue. Hosted mode refuses to start unless these are set, and names the missing ones: `KP_AUTHKIT_DOMAIN`, `KP_PUBLIC_MCP_URL`, `WORKOS_CLIENT_ID`, `WORKOS_API_KEY`, `WORKOS_COOKIE_PASSWORD` and `JAC_DB_URL`. To try it locally:

```bash
docker build -t knowledge-pool .
docker run --rm -p 8080:8080 -e PORT=8080 -e JAC_DB_URL=postgresql://... \
  -e KP_AUTHKIT_DOMAIN=https://x.authkit.app -e KP_PUBLIC_MCP_URL=https://x.example/mcp \
  -e WORKOS_CLIENT_ID=x -e WORKOS_API_KEY=x -e WORKOS_COOKIE_PASSWORD=<32+ characters> knowledge-pool
curl localhost:8080/healthz   # ok
```

Until the browser sign-in lands, hosted mode answers the health path and refuses everything else without a WorkOS bearer token, the page included.

### Layout

- `main.jac` entry point, joins server and client
- `catalog/` Python ingest (`ingest.py`) and search (`store.py`) over `data/catalog.sqlite`
- `cards.jac` the `Card` node and the `search_cards` endpoint
- schemas/mtgdeck-1.schema.json the published mtgdeck/1 deck document schema
- `deckformats/` the deck import/export format strategies (mtgdeck/1, MTGJSON Deck JSON, plain/Arena/Moxfield text)
- `decks.jac` the `Deck` node, the `Holds` edge, the deck walkers, `card_lines` and `deck_view`
- `deck_io.jac` the `DeckExport`, `DeckImport` and `CreateDeckFromList` walkers
- `export_panel.jac` the per-deck Export panel (format, preview, copy, download)
- `mana_panel.jac`, `card_search.jac` (`AddCards`) the deck page's mana and search sections
- `mana_cost.jac` mana costs as symbol pills (the MCP views draw the same)
- `global.css` app-wide style tokens, shared with the MCP Apps views in `ui/`
- `legality.jac` `Format` nodes and the deck-construction rules
- `mcp_server.jac` the MCP server and, over HTTP, the process that starts the front door
- `front_door.jac` the front door: the page's deck calls through the runner in Jac's own envelope, the page and its static files forwarded from Jac's server (a child on `127.0.0.1`), everything else 404, a health path
- `graph_runner.jac` the runner: runs every deck call as a caller on that caller's own root (the local user in local mode, `KP_MODE`), and the app's own work as the guest, for the MCP server and the seed script
- `seed.jac`, `catalog/precons.py` the seed script: one random MTGJSON precon per format
- `ui/` the MCP Apps views: `deck_table.html` (`deck_show`), `mana_analysis.html` (`deck_analyze`), `card_search.html` (`card_search`) and `deck_export.html` (`deck_export`); `ui/mockups/` holds the signed-off static mockups
- `scripts/mcp_smoke.py` an MCP client session that checks the tools end to end
- `frontend.jac`, `frontend.impl.jac` the Decks view
- `deck_detail.jac`, `deck_detail.impl.jac` one deck: search, add, change, remove
- `tests/` walker, REST and UI smoke tests
- `jac.toml` the Jac version pin, dependencies, and `[scripts]`, the repo's commands (`jac x` lists them): `check`, `up`, `down`, `status`, `catalogue`, `test-ui`
- `scripts/dev.sh` runs the front door (and its child) for this worktree (`up|down|status|port`)
- `Dockerfile`, `.dockerignore`, `catalogue_date.txt` the hosted container image
- `scripts/install_jac.sh` installs the Jac version `jac.toml` pins
- `scripts/board.sh` moves an issue on the project board (`scripts/board.sh <issue> <status>`)
- `scripts/fixture_cards.py` adds cards to `tests/fixtures/atomic_small.json`
- `CODING_STANDARDS.md` recurring review findings

### Spikes

- [S02: Jac go/no-go](docs/spikes/s02-jac-go-no-go.md): go, with the catalogue graph held in memory. Code in `spike/`.
