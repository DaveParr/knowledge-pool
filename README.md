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
```

### Run

```bash
uv run jac start main.jac
```

Open http://localhost:8000. The Decks view lists your decks and creates new ones. Decks are stored in `.jac/data` and survive a restart; delete that folder to start fresh.

### Test

```bash
uv run jac test        # walker tests in tests/*_tests.jac
uv run pytest tests    # REST tests, including a restart test
```

Type-check with `uv run jac check main.jac decks.sv.jac frontend.cl.jac frontend.impl.jac`. Run `jac guide` for Jac's own reference guides (see `AGENTS.md`).

### Layout

- `main.jac` entry point, joins server and client
- `decks.sv.jac` the `Deck` node and the `CreateDeck` / `ListDecks` walkers
- `frontend.cl.jac`, `frontend.impl.jac` the Decks view
- `tests/` walker and REST tests
