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
uv run pytest tests                  # expect 123 passed
uv run jac test                      # expect all passed
uv run jac check *.jac               # expect no errors (warnings are fine)
uv run python scripts/mcp_smoke.py   # expect "all checks passed", including the 3 export/import lines
```

## 3. Manual QA in the app

Start the app with `uv run jac start main.jac` and open http://localhost:8000.

Import isn't a section of its own. It's an expander on the deck list: press **Import list ▾** next to **Create deck**, pick a format, paste a list and press **Create from list**. Every import makes a new deck. Replacing an existing deck's cards from a list is only available over MCP (`deck_import`). Export is the small **Export ▾** button on each deck row and in each deck's header. It opens a panel showing the export as MTGA/MTGO, with buttons to switch format, **Copy** and **Download**.

### Import a pasted list (Moxfield or Arena)

Type **QA Burn** as the deck name, open **Import list ▾**, choose **Moxfield**, paste this and press **Create from list**:

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

- [ ] The new deck opens, called QA Burn. It holds Lightning Bolt 4, Goblin Guide 4, Monastery Swiftspear 4 and Mountain 40 in the main deck, plus Smash to Smithereens 3 and Roiling Vortex 2 marked **Sideboard**. The set code `(2X2) 117` is ignored.
- [ ] **Lines that didn't resolve** at the top of the deck lists `Lightening Bolt` and `Flargle the Unreal`. Neither is added. The misspelling is not quietly fixed. The box goes away when you go back to the deck list.
- [ ] The deck is set to Standard, because **Play format** was left on its default and text lists don't name a format.

Import the same list again, this time with **Play format** set to **Modern**.

- [ ] The new deck opens set to Modern, and the legality box only complains about the card count (52 main-deck cards), not about cards being illegal in Standard.

Now try the Arena style. Go back, leave the name blank, choose **MTGA/MTGO** and paste:

```
Deck
4 Lightning Bolt (2X2) 117
56 Mountain (ZNR) 381

Sideboard
4 Smash to Smithereens
```

- [ ] A deck called **Imported deck** opens with 60 main-deck cards and 4 in the sideboard.
- [ ] `Deck` is read as a header, not as a card.
- [ ] With the expander closed, **Create deck** with a blank name still says "A deck needs a name."

### Export panel

On the deck list, press **Export ▾** on QA Burn.

- [ ] A panel opens under the row showing the deck as **MTGA/MTGO**, with a yellow note that the format is lossy.
- [ ] Press **Moxfield**: the text changes. Press **mtgdeck/1**: the note turns green ("Lossless") and the download button says **Download .json**.
- [ ] **Copy** shows "Copied", and pasting into a text editor gives the list. If the browser refuses clipboard access, the text is selected instead with "Press Ctrl+C (Cmd+C) to copy".
- [ ] **Download** saves `qa-burn.txt` (or `.json`).
- [ ] Do the same from inside the deck (the button by the deck name).

Check each format's shape:

- [ ] **mtgdeck/1**: JSON with `"schema": "mtgdeck/1"`, a `name`, `format` and `zones`.
- [ ] **MTGJSON**: JSON with `mainBoard` and `sideBoard` arrays.
- [ ] **Plain text**: `4 Lightning Bolt` lines, with the sideboard after a blank line and a `Sideboard` header.
- [ ] **MTGA/MTGO**: as plain text, but starting with a `Deck` header.
- [ ] **Moxfield**: as plain text.

### Round trip: mtgdeck/1 export, then import

1. Open QA Burn, set it to **Modern**, and export it as **mtgdeck/1**.
2. Back on the deck list, leave the name blank, open **Import list ▾**, choose **mtgdeck/1**, paste and press **Create from list**.

- [ ] With **Play format** on "From the list (mtgdeck/1), else Standard", a new deck called QA Burn opens, set to Modern, with the same cards, counts and zones as the original.
- [ ] Nothing is listed under **Lines that didn't resolve**.

### Exports validate against the published schema

Check that `schemas/mtgdeck-1.schema.json` exists, then paste an mtgdeck/1 export into `/tmp/qa-export.json` and run:

```bash
uv run python -c "import json, jsonschema; jsonschema.validate(json.load(open('/tmp/qa-export.json')), json.load(open('schemas/mtgdeck-1.schema.json'))); print('valid')"
```

- [ ] It prints `valid`.

### Bad input never makes a deck

Count the decks on the list first. After each paste below, an error starting "Nothing imported, so no deck was created" shows, and the deck count doesn't change.

- [ ] Choose **mtgdeck/1** and paste `not json at all`. The error includes the parse error.
- [ ] Choose **mtgdeck/1** and paste `{"schema": "mtgdeck/2", "name": "x", "zones": {}}`. The error names the schema.
- [ ] Choose **Plain text** and paste `hello world`. The error lists `hello world`.
- [ ] Choose **Plain text** and paste `3 Flargle the Unreal`. The error lists `Flargle the Unreal`.
- [ ] Clear the box and press **Create from list**. You see "Paste a deck list to import."
- [ ] Paste a **MTGJSON Deck JSON** export with **mtgdeck/1** selected. The error says `schema` must be "mtgdeck/1".

### Duplicates are summed

Import this as **Plain text**:

```
2 Lightning Bolt
2 Lightning Bolt
56 Mountain
```

- [ ] Lightning Bolt shows 4, not 2.

### Commander, companion and maybeboard zones

Import this as **mtgdeck/1**:

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

- [ ] A deck called Zones test opens, with nothing unresolved.
- [ ] Export it as **mtgdeck/1**. Krenko is under `commander` with its role and reason, Goblin Guide keeps `tags` and `locked: true`, and Lightning Bolt is under `maybeboard`.
- [ ] Look at the deck table. **Known gap:** only sideboard cards are labelled, so Krenko and the maybeboard Lightning Bolt look like main-deck cards in the table. Decide whether this needs fixing before merging or in S06 (Commander support).

Text headers work too. Import this as **Plain text**:

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
- [ ] Ask Claude to import a different list into that same deck. The cards are **replaced**, not added to.
- [ ] Open http://localhost:8000. The imported deck is there with the same cards.
