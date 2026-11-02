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

Open http://localhost:8000. The Decks view lists your decks and creates new ones. Open a deck to search cards by name or rules text, add them to the main deck or sideboard, change counts and remove them. Each deck has a format (Standard, Pioneer or Modern), and the deck view shows straight away whether it is legal and lists each rule it breaks: at least 60 main-deck cards, at most 15 in the sideboard, at most 4 copies of a card across both (basic lands and "any number" cards are exempt, and cards like Seven Dwarves use their own limit), and every card legal in the format according to MTGJSON. Legality is worked out on every view and edit; it is never stored. Decks are stored in `.jac/data` and survive a restart; delete that folder to start fresh.

The full catalogue stays in SQLite. A `Card` node is added to the graph the first time a deck uses that card, because saving all 35,000 cards as graph nodes took more than 15 minutes.

### Test

```bash
uv run jac test        # walker tests in tests/*_tests.jac
uv run pytest tests    # ingest, search and REST tests, including restart tests
```

`tests/fixtures/legality_decks.json` holds 27 known legal and illegal decks that the validator is tested against. Tests build their catalogue from `tests/fixtures/atomic_small.json`, 31 real cards taken from MTGJSON (legalities as of 2 Nov 2026). Type-check with `uv run jac check *.jac`. Run `jac guide` for Jac's own reference guides (see `AGENTS.md`).

### Layout

- `main.jac` entry point, joins server and client
- `catalog/` Python ingest (`ingest.py`) and search (`store.py`) over `data/catalog.sqlite`
- `cards.sv.jac` the `Card` node and the `search_cards` endpoint
- `decks.sv.jac` the `Deck` node, the `Holds` edge, the deck walkers and `ValidateDeck`
- `legality.sv.jac` `Format` nodes and the deck-construction rules
- `frontend.cl.jac`, `frontend.impl.jac` the Decks view
- `deck_detail.cl.jac`, `deck_detail.impl.jac` one deck: search, add, change, remove
- `tests/` walker and REST tests
