# S05 QA: deck import and export (mtgdeck/1)

Checks #37 by hand on branch `DaveParr/s05-deck-import-and-export-mtgdeck-1`. Each acceptance criterion from the issue has its own section, followed by checks for the edge cases fixed during the build.

## 1. Set up

```bash
uv sync --locked
uv run python -m catalog.ingest    # skip if data/catalog.sqlite already exists
mv .jac/data .jac/data.before-qa   # optional: keep your decks out of the way
```

To put your own decks back afterwards, run `rm -rf .jac/data && mv .jac/data.before-qa .jac/data`.

## 2. Automated checks

```bash
uv run pytest tests                  # expect 116 passed
uv run jac test                      # expect all passed
uv run jac check *.jac               # expect no errors (warnings are fine)
uv run python scripts/mcp_smoke.py   # expect "all checks passed", including the 3 export/import lines
```

## 3. Manual QA in the app

Start the app with `uv run jac start main.jac` and open http://localhost:8000. Create a deck called **QA Burn**, set it to **Modern** and open it. The Export and Import sections are below the card search.

### Import a pasted list (Moxfield or Arena)

Choose **Moxfield** in the Import dropdown, paste this, then press **Import**:

```
4 Lightning Bolt (2X2) 117
4 Goblin Guide
4 Monastery Swiftspear
4 Lightening Bolt
2 Flargle the Unreal
40 Mountain

Sideboard
3 Smash to Smithereens
2 Roiling Vortex
```

- [ ] The deck now holds Lightning Bolt 4, Goblin Guide 4, Monastery Swiftspear 4 and Mountain 40 in the main deck, plus Smash to Smithereens 3 and Roiling Vortex 2 marked **Sideboard**. The set code `(2X2) 117` is ignored.
- [ ] **Lines that didn't resolve** lists `Lightening Bolt` and `Flargle the Unreal`. Neither is added. The misspelling is not quietly fixed.
- [ ] The legality box updates (52 main-deck cards, so Modern says it needs 60).

Now try the Arena style. Choose **MTGA/MTGO** and paste:

```
Deck
4 Lightning Bolt (2X2) 117
56 Mountain (ZNR) 381

Sideboard
4 Smash to Smithereens
```

- [ ] The import **replaces** the deck rather than adding to it: Goblin Guide and the others are gone, and the main deck is now 60 cards.
- [ ] `Deck` is read as a header, not as a card.

### Round trip: mtgdeck/1 export, then import

1. Choose **mtgdeck/1** under Export and press **Export**. Copy the JSON from the read-only box.
2. Change the deck: set Lightning Bolt to 1 and remove the sideboard card.
3. Choose **mtgdeck/1** under Import, paste the copied JSON and press **Import**.

- [ ] The deck is back exactly as it was at step 1: same cards, counts and zones.
- [ ] Nothing is listed under **Lines that didn't resolve**.

Export the deck in the other formats too:

- [ ] **MTGJSON Deck JSON**: JSON with `mainBoard` and `sideBoard` arrays.
- [ ] **Plain text**: `4 Lightning Bolt` lines, with the sideboard after a blank line and a `Sideboard` header.
- [ ] **MTGA/MTGO**: as plain text, but starting with a `Deck` header.
- [ ] **Moxfield**: as plain text.

### Exports validate against the published schema

Check that `schemas/mtgdeck-1.schema.json` exists, then paste an mtgdeck/1 export into `/tmp/qa-export.json` and run:

```bash
uv run python -c "import json, jsonschema; jsonschema.validate(json.load(open('/tmp/qa-export.json')), json.load(open('schemas/mtgdeck-1.schema.json'))); print('valid')"
```

- [ ] It prints `valid`.

### Bad input never wipes the deck

Before each paste, note what the deck holds. After each one, the deck should be unchanged.

- [ ] Choose **mtgdeck/1** and paste `not json at all`. Nothing changes, and a parse error is shown under **Lines that didn't resolve**.
- [ ] Choose **mtgdeck/1** and paste `{"schema": "mtgdeck/2", "name": "x", "zones": {}}`. Nothing changes, and the error names the schema.
- [ ] Choose **Plain text** and paste `hello world`. Nothing changes, and `hello world` is listed as unresolved.
- [ ] Choose **Plain text** and paste `3 Flargle the Unreal`. Nothing changes, because nothing resolved.
- [ ] Clear the Import box and press **Import**. Nothing changes, and you see "Nothing to import: no cards found."
- [ ] Export as **MTGJSON Deck JSON**, then paste that into Import with **mtgdeck/1** selected. Nothing changes, and the error says `schema` must be "mtgdeck/1".

### Duplicates are summed

Choose **Plain text** and paste:

```
2 Lightning Bolt
2 Lightning Bolt
56 Mountain
```

- [ ] Lightning Bolt shows 4, not 2.

### Commander, companion and maybeboard zones

Choose **mtgdeck/1** and paste:

```json
{
  "schema": "mtgdeck/1",
  "name": "Zones test",
  "zones": {
    "commander": [{"name": "Krenko, Mob Boss", "count": 1, "roles": ["commander"], "reason": "goblin tribal"}],
    "main": [{"name": "Goblin Guide", "count": 4, "tags": ["haste"], "locked": true}],
    "maybeboard": [{"name": "Lightning Bolt", "count": 2}]
  }
}
```

- [ ] The import works, with nothing unresolved.
- [ ] Export as **mtgdeck/1**. Krenko is under `commander` with its role and reason, Goblin Guide keeps `tags` and `locked: true`, and Lightning Bolt is under `maybeboard`.
- [ ] Look at the deck table. **Known gap:** only sideboard cards are labelled, so Krenko and the maybeboard Lightning Bolt look like main-deck cards in the table. Decide whether this needs fixing before merging or in S06 (Commander support).

Text headers work too. Choose **Plain text** and paste:

```
Commander
1 Krenko, Mob Boss

Deck
4 Goblin Guide
```

- [ ] An mtgdeck/1 export puts Krenko under `commander` and Goblin Guide under `main`.
- [ ] **Known limit:** without the `Deck` line, Goblin Guide is also filed as a commander. A test pins this behaviour.

## 4. Claude over MCP (optional)

Stop `jac start` first, because the MCP server runs the web app itself. If `knowledge-pool` isn't registered yet:

```bash
claude mcp add knowledge-pool -- uv run --directory "$PWD" jac run mcp_server.jac
```

In a new Claude Code session:

- [ ] Ask: "Using knowledge-pool, export my QA Burn deck as mtgdeck/1." Claude calls `deck_export` and shows the JSON.
- [ ] Ask Claude to import an Arena list containing one misspelt card into a new deck. Claude calls `deck_import`, and the result lists the misspelt line as unresolved.
- [ ] Open http://localhost:8000. The imported deck is there with the same cards.
