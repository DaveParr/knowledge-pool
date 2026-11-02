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

```bash
uv sync
uv run python -m catalog.ingest
```

The ingest downloads MTGJSON's `AtomicCards.json.xz` (about 26 MB) and builds `data/catalog.sqlite`: one row per oracle card plus an FTS5 search index, with the MTGJSON version and build date in its `meta` table. It takes a few seconds. Pass `--source FILE` to build from a file you already have. Run it again to pick up a newer MTGJSON build.

### Run

```bash
uv run jac start main.jac
```

Open http://localhost:8000. The Decks view lists your decks and creates new ones. Open a deck to search cards by name or rules text, add them, change counts and remove them. Decks are stored in `.jac/data` and survive a restart; delete that folder to start fresh.

The full catalogue stays in SQLite. A `Card` node is added to the graph the first time a deck uses that card, because saving all 35,000 cards as graph nodes took more than 15 minutes.

### Test

```bash
uv run jac test        # walker tests in tests/*_tests.jac
uv run pytest tests    # ingest, search and REST tests, including restart tests
```

Tests build their catalogue from `tests/fixtures/atomic_small.json`, 16 real cards taken from MTGJSON. Type-check with `uv run jac check *.jac`. Run `jac guide` for Jac's own reference guides (see `AGENTS.md`).

### Layout

- `main.jac` entry point, joins server and client
- `catalog/` Python ingest (`ingest.py`) and search (`store.py`) over `data/catalog.sqlite`
- `cards.sv.jac` the `Card` node and the `search_cards` endpoint
- `decks.sv.jac` the `Deck` node, the `Holds` edge and the deck walkers
- `frontend.cl.jac`, `frontend.impl.jac` the Decks view
- `deck_detail.cl.jac`, `deck_detail.impl.jac` one deck: search, add, change, remove
- `tests/` walker and REST tests
