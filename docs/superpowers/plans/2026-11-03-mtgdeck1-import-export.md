# Deck import and export (mtgdeck/1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A deck can be exported losslessly to `mtgdeck/1` and to MTGJSON Deck JSON, exported lossily to plain text, MTGA/MTGO text and Moxfield text, and imported back from any of those text formats, with unresolved lines flagged and never turned into invented cards — available both as `:pub` walkers (so the app's REST API gets them for free) and as `deck_export`/`deck_import` MCP tools.

**Architecture:** A new pure-Python `deckformats` package holds one small class per format behind a `DeckFormat` protocol (`parse(text) -> ParsedDeck`, `render(deck) -> str`), collected in a `FORMATS` registry keyed by format name. Two new Jac walkers, `DeckExport` and `DeckImport` in `deck_io.sv.jac`, depend only on that registry (`get_format(name)`) — this is the dependency injection: the walkers never branch on format, they just look up the strategy. `decks.sv.jac` grows the zone set from 2 to 5 and the `Holds` edge grows `role`/`tags`/`locked`/`reason`, so a deck can hold the full `mtgdeck/1` shape; the legality validator is adjusted to keep ignoring the three new zones, so existing 60-card-format behaviour is unchanged.

**Tech Stack:** Jac (`jaclang` 0.16.7, walkers/nodes/edges), plain Python 3.12 for the new `deckformats` package, `jsonschema` (dev-only) to pin the schema in tests, `pytest` + `jaclang.runtimelib.testing.JacTestClient` for REST-level tests, `jac test` for catalog-free walker-level tests.

**Spec:** GitHub issue [DaveParr/knowledge-pool#37](https://github.com/DaveParr/knowledge-pool/issues/37) ("S05: Deck import and export (mtgdeck/1)") and its acceptance criteria; design context in the linked Claude Docs [original proposal](https://claude.ai/artifact/NS3Yns3rWfQLLANXUjBjcr) (defines the `mtgdeck/1` shape and its design rules) and [Jac design](https://claude.ai/artifact/7ZiZgUG2PX198AWwtAEcCN) (confirms `mtgdeck/1` carries over unchanged into the Jac implementation). No local written-design doc exists for this slice — the issue and linked docs are the spec of record, per explicit user direction to proceed straight to a plan. TopDecked CSV import, previously scoped as a bonus format from a sample attached to issue #37, is explicitly out of scope per user direction.

## Global Constraints

- `mtgdeck/1` zones are fixed: `commander`, `companion`, `main`, `sideboard`, `maybeboard` (issue #37; design doc).
- Each `mtgdeck/1` entry may carry `role`, `tags`, `locked`, `reason`, in addition to `name`/`oracleId`/`count` (issue #37).
- Export is lossless to `mtgdeck/1` and to MTGJSON Deck JSON; export is lossy (and import-compatible) for plain text, MTGA/MTGO text and Moxfield text (issue #37).
- Import must flag lines that don't resolve and must never add an invented card (issue #37 acceptance criteria).
- The round trip "export `mtgdeck/1` then import" must give back the same deck (issue #37 acceptance criteria).
- The schema must be published in the repo, and exports must validate against it (issue #37 acceptance criteria).
- The tools are `deck_import` and `deck_export`, and the feature must also be reachable in the app (issue #37) — satisfied by making both Jac walkers `:pub`.
- Cards are identified by name plus MTGJSON oracle-level identity; a printing UUID is optional and deck logic never depends on which printing was chosen (design doc) — our MTGJSON Deck JSON export therefore emits `name`/`count` only, no `uuid`.
- No tool call in this feature may call a model (`by llm`); resolving a name to a card is exact-match only, same rule MCP's `resolve_names` already follows (`mcp_server.jac` docstring; `catalog/store.py:resolve_names`).
- Dependencies are pinned to exact versions via `uv add`/`uv remove`, never `jac add` (README.md).

## Review Focus

- A pasted import line that matches no known line shape at all (stray text, a header typo, trailing whitespace-only line) must show up as unresolved, not silently vanish or crash the import. → Task 4's `test_a_line_that_is_not_count_and_name_is_unparsed_not_dropped`, surfaced end-to-end in Task 7's `test_import_flags_unresolved_lines_and_never_invents_a_card`.
- Importing into a deck that already has cards is a surprising place to improvise: this plan makes import a full replace (old holdings are deleted first), not a merge, so re-importing a trimmed list actually drops the cut cards. → Task 7's `test_importing_a_new_list_replaces_what_was_there_before`.
- An unknown format name (a typo like `"mtgdeck"`) must fail cleanly — no report from the walker, no 500 — for both export and import. → Task 6's `test_export_with_an_unknown_format_reports_nothing` and Task 7's `test_import_with_an_unknown_format_reports_nothing`.
- A `commander`/`companion`/`maybeboard` entry that round-trips through `mtgdeck/1` must not get swept into the 60-card format's main-deck size or copy-limit totals, since the validator only knows about `main`/`sideboard` today. → Task 5's zone-filter change, exercised by Task 7's `test_commander_zone_entries_do_not_count_toward_main_deck_legality`.
- An Arena-style decorated line (`"4 Lightning Bolt (M10) 146"`) must still resolve to the plain card name, not fail just because of the set/collector-number suffix. → Task 4's `test_arena_strips_the_set_and_collector_number_suffix`.

---

## File Structure

- Create `schemas/mtgdeck-1.schema.json` — the published JSON Schema for the `mtgdeck/1` document.
- Create `deckformats/__init__.py` — the `FORMATS` registry and `get_format(name)` lookup (the DI seam).
- Create `deckformats/base.py` — `ParsedEntry`, `ParsedDeck`, `ExportEntry`, `ExportDeck`, the `DeckFormat` protocol.
- Create `deckformats/mtgdeck1.py` — lossless `mtgdeck/1` parse/render.
- Create `deckformats/mtgjson.py` — lossless-for-our-model MTGJSON Deck JSON render (export only).
- Create `deckformats/linelist.py` — one configurable parser/renderer shared by `text`, `arena` and `moxfield`.
- Create `deck_io.sv.jac` — `DeckExport`/`DeckImport` walkers and their `ExportResult`/`ImportResult` report objects.
- Modify `decks.sv.jac` — widen the zone set, add entry metadata to `Holds`/`DeckCard`, add `set_card_entry`, keep `ValidateDeck` scoped to `main`/`sideboard`.
- Modify `mcp_server.jac` — add `deck_export`/`deck_import` tools.
- Modify `deck_detail.cl.jac` / `deck_detail.impl.jac` — export/import controls in the app.
- Modify `scripts/mcp_smoke.py` — exercise the two new tools end to end.
- Modify `README.md` — list the new files under Layout.
- Create `tests/test_deckformats.py`, `tests/decks_io_tests.jac`, `tests/test_deck_io.py`.

---

### Task 1: Publish the `mtgdeck/1` JSON Schema

**Files:**
- Create: `schemas/mtgdeck-1.schema.json`
- Test: `tests/test_deckformats.py` (new file, started here)

**Interfaces:**
- Produces: a schema file at `schemas/mtgdeck-1.schema.json` that later tasks validate rendered documents against.

- [ ] **Step 1: Add the `jsonschema` dev dependency**

Run: `uv add --dev jsonschema`
Expected: `pyproject.toml` gains a `jsonschema` entry under `[dependency-groups] dev` and `uv.lock` is updated in the same command.

- [ ] **Step 2: Verify the lockfile is consistent**

Run: `uv sync --locked`
Expected: succeeds (no "lockfile is out of date" error).

- [ ] **Step 3: Create `schemas/mtgdeck-1.schema.json`** with exactly this content:

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://github.com/DaveParr/knowledge-pool/schemas/mtgdeck-1.schema.json",
  "title": "mtgdeck/1",
  "type": "object",
  "required": ["schema", "name", "zones"],
  "additionalProperties": false,
  "properties": {
    "schema": { "const": "mtgdeck/1" },
    "name": { "type": "string" },
    "format": { "type": "string" },
    "brief": {
      "type": "object",
      "properties": {
        "archetype": { "type": "string" },
        "themes": { "type": "array", "items": { "type": "string" } },
        "budgetUsd": { "type": "number" }
      },
      "additionalProperties": true
    },
    "seeds": { "type": "array", "items": { "type": "string" } },
    "zones": {
      "type": "object",
      "additionalProperties": false,
      "properties": {
        "commander": { "$ref": "#/$defs/entryList" },
        "companion": { "$ref": "#/$defs/entryList" },
        "main": { "$ref": "#/$defs/entryList" },
        "sideboard": { "$ref": "#/$defs/entryList" },
        "maybeboard": { "$ref": "#/$defs/entryList" }
      }
    },
    "validation": {
      "type": "object",
      "properties": {
        "legal": { "type": "boolean" },
        "mtgjsonVersion": { "type": "string" },
        "checkedAt": { "type": "string" }
      },
      "additionalProperties": true
    }
  },
  "$defs": {
    "entryList": {
      "type": "array",
      "items": { "$ref": "#/$defs/entry" }
    },
    "entry": {
      "type": "object",
      "required": ["name", "count"],
      "additionalProperties": false,
      "properties": {
        "name": { "type": "string" },
        "oracleId": { "type": "string" },
        "count": { "type": "integer", "minimum": 1 },
        "role": { "type": "string" },
        "tags": { "type": "array", "items": { "type": "string" } },
        "locked": { "type": "boolean" },
        "reason": { "type": "string" }
      }
    }
  }
}
```

`brief`, `seeds` and `validation` are schema-legal but this slice's exporter never populates them (we have no archetype/theme/budget/seed data on `Deck`, and the design doc says `validation` is "derived, always recomputed, never trusted on import" — so leaving it out of our export is correct, not a gap).

- [ ] **Step 4: Write the failing test**

```python
import json
from pathlib import Path

import jsonschema

SCHEMA = json.loads((Path(__file__).parent.parent / "schemas" / "mtgdeck-1.schema.json").read_text())


def test_schema_file_is_a_valid_json_schema():
    jsonschema.Draft202012Validator.check_schema(SCHEMA)
```

- [ ] **Step 5: Run it**

Run: `uv run pytest tests/test_deckformats.py -v`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add schemas/mtgdeck-1.schema.json tests/test_deckformats.py pyproject.toml uv.lock
git commit -m "Publish the mtgdeck/1 JSON Schema"
```

---

### Task 2: `deckformats` base types, registry and the `mtgdeck1` format

**Files:**
- Create: `deckformats/__init__.py`, `deckformats/base.py`, `deckformats/mtgdeck1.py`
- Test: `tests/test_deckformats.py` (append)

**Interfaces:**
- Consumes: `schemas/mtgdeck-1.schema.json` (Task 1).
- Produces (used by every later task):
  - `deckformats.base.ParsedEntry(raw_name: str, count: int, zone: str = "main", oracle_id: str = "", role: str = "", tags: list[str] = [], locked: bool = False, reason: str = "")`
  - `deckformats.base.ParsedDeck(name: str = "", format: str = "", entries: list[ParsedEntry] = [], unparsed: list[str] = [])`
  - `deckformats.base.ExportEntry(oracle_id: str, name: str, count: int, zone: str, role: str = "", tags: list[str] = [], locked: bool = False, reason: str = "")`
  - `deckformats.base.ExportDeck(name: str, format: str, entries: list[ExportEntry])`
  - `deckformats.base.DeckFormat` protocol: `parse(text: str) -> ParsedDeck`, `render(deck: ExportDeck) -> str`
  - `deckformats.get_format(name: str) -> DeckFormat`, raising `ValueError(f"Unknown deck format: {name}. Use one of: ...")` for an unregistered name
  - `deckformats.DECK_ZONES = ("commander", "companion", "main", "sideboard", "maybeboard")`

- [ ] **Step 1: Write the failing tests**

```python
import pytest

from deckformats import ExportDeck, ExportEntry, get_format


def _sample_deck() -> ExportDeck:
    return ExportDeck(
        name="Izzet Spells",
        format="pioneer",
        entries=[
            ExportEntry(oracle_id="o1", name="Ledger Shredder", count=4, zone="main", role="threat", tags=["spells-matter"], locked=True),
            ExportEntry(oracle_id="o2", name="Consider", count=4, zone="main", reason="cantrip"),
            ExportEntry(oracle_id="o3", name="Unlicensed Hearse", count=2, zone="sideboard"),
            ExportEntry(oracle_id="o4", name="Atraxa, Grand Unifier", count=1, zone="commander"),
        ],
    )


def test_render_mtgdeck1_validates_against_the_schema():
    import json
    doc = json.loads(get_format("mtgdeck1").render(_sample_deck()))
    jsonschema.validate(doc, SCHEMA)
    assert doc["schema"] == "mtgdeck/1"
    assert {e["name"] for e in doc["zones"]["main"]} == {"Ledger Shredder", "Consider"}


def test_parse_mtgdeck1_round_trips_every_field():
    fmt = get_format("mtgdeck1")
    parsed = fmt.parse(fmt.render(_sample_deck()))
    by_name = {e.raw_name: e for e in parsed.entries}
    assert by_name["Ledger Shredder"].count == 4
    assert by_name["Ledger Shredder"].zone == "main"
    assert by_name["Ledger Shredder"].role == "threat"
    assert by_name["Ledger Shredder"].tags == ["spells-matter"]
    assert by_name["Ledger Shredder"].locked is True
    assert by_name["Ledger Shredder"].oracle_id == "o1"
    assert by_name["Atraxa, Grand Unifier"].zone == "commander"
    assert by_name["Consider"].reason == "cantrip"


def test_get_format_rejects_unknown_name():
    with pytest.raises(ValueError, match="Unknown deck format"):
        get_format("not-a-format")
```

(Add `jsonschema`/`json`/`SCHEMA` to this file's existing imports from Task 1 rather than redefining them.)

- [ ] **Step 2: Run them to see they fail**

Run: `uv run pytest tests/test_deckformats.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'deckformats'`

- [ ] **Step 3: Implement `deckformats/base.py`**

Plain `@dataclass` definitions for `ParsedEntry`, `ParsedDeck`, `ExportEntry`, `ExportDeck` exactly as specified in Interfaces above (list/dict defaults via `field(default_factory=list)`), plus a `DeckFormat` `Protocol` (from `typing`) with the two methods.

- [ ] **Step 4: Implement `deckformats/mtgdeck1.py`**

`class Mtgdeck1Format` with:
- `render(self, deck: ExportDeck) -> str`: group `deck.entries` by `e.zone` into a `zones` dict; each entry becomes `{"name": e.name, "oracleId": e.oracle_id, "count": e.count}` plus `role`/`tags`/`locked`/`reason` keys only when truthy (so the output stays minimal, matching the design doc's example). Wrap as `{"schema": "mtgdeck/1", "name": deck.name, "format": deck.format, "zones": zones}` and `json.dumps(doc, indent=2)`.
- `parse(self, text: str) -> ParsedDeck`: `json.loads(text)`, then one `ParsedEntry` per entry per zone key in `doc.get("zones", {})`, reading `oracleId`/`role`/`tags`/`locked`/`reason` with the same defaults as `ParsedEntry`'s own defaults (so a field absent from the JSON round-trips to the same default `ParsedEntry()` would have). `name`/`format` come from `doc.get("name", "")` / `doc.get("format", "")`.

- [ ] **Step 5: Implement `deckformats/__init__.py`**

```python
from deckformats.base import DeckFormat, ExportDeck, ExportEntry, ParsedDeck, ParsedEntry
from deckformats.mtgdeck1 import Mtgdeck1Format

DECK_ZONES = ("commander", "companion", "main", "sideboard", "maybeboard")

FORMATS: dict[str, DeckFormat] = {
    "mtgdeck1": Mtgdeck1Format(),
}


def get_format(name: str) -> DeckFormat:
    try:
        return FORMATS[name]
    except KeyError:
        raise ValueError(f"Unknown deck format: {name}. Use one of: {', '.join(sorted(FORMATS))}.") from None
```

(Tasks 3 and 4 each add one or more entries to `FORMATS` and the corresponding `from deckformats.X import Y` line; nothing else in this file changes.)

- [ ] **Step 6: Run the tests again**

Run: `uv run pytest tests/test_deckformats.py -v`
Expected: PASS

- [ ] **Step 7: Commit**

```bash
git add deckformats/ tests/test_deckformats.py
git commit -m "Add the mtgdeck/1 deck format (base types, registry, parse/render)"
```

---

### Task 3: MTGJSON Deck JSON export

**Files:**
- Create: `deckformats/mtgjson.py`
- Modify: `deckformats/__init__.py`
- Test: `tests/test_deckformats.py` (append)

**Interfaces:**
- Consumes: `ExportDeck`/`ExportEntry` (Task 2).
- Produces: registry key `"mtgjson"` whose `render` returns MTGJSON-shaped JSON; `parse` always raises `NotImplementedError`.

- [ ] **Step 1: Write the failing tests**

```python
def test_render_mtgjson_groups_entries_by_zone():
    doc = json.loads(get_format("mtgjson").render(_sample_deck()))
    assert {e["name"]: e["count"] for e in doc["mainBoard"]} == {"Ledger Shredder": 4, "Consider": 4}
    assert {e["name"]: e["count"] for e in doc["sideBoard"]} == {"Unlicensed Hearse": 2}
    assert {e["name"]: e["count"] for e in doc["commander"]} == {"Atraxa, Grand Unifier": 1}


def test_mtgjson_does_not_support_import():
    with pytest.raises(NotImplementedError):
        get_format("mtgjson").parse("anything")
```

- [ ] **Step 2: Run them to see they fail**

Run: `uv run pytest tests/test_deckformats.py -v`
Expected: FAIL — `KeyError: 'mtgjson'`

- [ ] **Step 3: Implement `deckformats/mtgjson.py`**

```python
MTGJSON_ZONE_KEYS = {
    "commander": "commander", "companion": "companion", "main": "mainBoard",
    "sideboard": "sideBoard", "maybeboard": "maybeboard",
}
```
`class MtgjsonFormat`: `render` builds `{"name": deck.name, "code": "", **{key: [] for key in MTGJSON_ZONE_KEYS.values()}}`, appends `{"count": e.count, "name": e.name}` into `doc[MTGJSON_ZONE_KEYS[e.zone]]` for each entry, returns `json.dumps(doc, indent=2)`. `parse` raises `NotImplementedError("mtgjson import is not supported")`.

- [ ] **Step 4: Register it** — add `from deckformats.mtgjson import MtgjsonFormat` and `"mtgjson": MtgjsonFormat()` to `deckformats/__init__.py`.

- [ ] **Step 5: Run the tests again**

Run: `uv run pytest tests/test_deckformats.py -v`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add deckformats/
git commit -m "Add lossless MTGJSON Deck JSON export"
```

---

### Task 4: Shared line-list format for `text`, `arena` and `moxfield`

**Files:**
- Create: `deckformats/linelist.py`
- Modify: `deckformats/__init__.py`
- Test: `tests/test_deckformats.py` (append)

**Interfaces:**
- Consumes: `ExportDeck`/`ParsedDeck`/`ParsedEntry` (Task 2).
- Produces: registry keys `"text"`, `"arena"`, `"moxfield"`, each a `LineListFormat` instance (import + export).

- [ ] **Step 1: Write the failing tests**

```python
@pytest.mark.parametrize("name", ["text", "arena", "moxfield"])
def test_round_trips_a_simple_main_and_sideboard_list(name):
    deck = ExportDeck(name="d", format="modern", entries=[
        ExportEntry(oracle_id="o1", name="Lightning Bolt", count=4, zone="main"),
        ExportEntry(oracle_id="o2", name="Mountain", count=20, zone="main"),
        ExportEntry(oracle_id="o3", name="Negate", count=2, zone="sideboard"),
    ])
    fmt = get_format(name)
    parsed = fmt.parse(fmt.render(deck))
    assert {(e.raw_name, e.count, e.zone) for e in parsed.entries} == {
        ("Lightning Bolt", 4, "main"), ("Mountain", 20, "main"), ("Negate", 2, "sideboard"),
    }


def test_arena_strips_the_set_and_collector_number_suffix():
    parsed = get_format("arena").parse("4 Lightning Bolt (M10) 146\n")
    assert parsed.entries[0].raw_name == "Lightning Bolt"
    assert parsed.entries[0].count == 4


def test_a_line_that_is_not_count_and_name_is_unparsed_not_dropped():
    parsed = get_format("text").parse("4 Lightning Bolt\nthis is not a deck line\n")
    assert parsed.unparsed == ["this is not a deck line"]
    assert len(parsed.entries) == 1
```

- [ ] **Step 2: Run them to see they fail**

Run: `uv run pytest tests/test_deckformats.py -v`
Expected: FAIL — `KeyError: 'text'`

- [ ] **Step 3: Implement `deckformats/linelist.py`**

`@dataclass class LineListFormat` with fields `deck_header: str | None = None`, `sideboard_header: str | None = "Sideboard"`, `strip_set_suffix: bool = False`.

`render(self, deck: ExportDeck) -> str`: only `main` and `sideboard` zone entries are emitted (commander/companion/maybeboard are intentionally dropped here — that is this format's documented lossiness). Emit `self.deck_header` as a first line if set; one `f"{e.count} {e.name}"` line per `main` entry; if there are `sideboard` entries, a blank line, `self.sideboard_header` if set, then one line per sideboard entry. Join with `"\n"`, trailing newline.

`parse(self, text: str) -> ParsedDeck`: track `current_zone = "main"`; build a case-insensitive header→zone map from `{self.deck_header: "main", self.sideboard_header: "sideboard"}` (skipping `None` keys); for each line (`text.splitlines()`), skip blank lines, switch `current_zone` on a header match, otherwise match `^(\d+)x?\s+(.+)$` — on no match append the raw line to `parsed.unparsed`; on match, `name = match.group(2).strip()`, and if `self.strip_set_suffix`, additionally strip a trailing `r"\s*\([A-Za-z0-9]{2,5}\)\s*[A-Za-z0-9\-★]*$"` match off `name` before building the `ParsedEntry(raw_name=name, count=int(match.group(1)), zone=current_zone)`.

- [ ] **Step 4: Register three instances** — add `from deckformats.linelist import LineListFormat` and:
```python
"text": LineListFormat(),
"arena": LineListFormat(deck_header="Deck", strip_set_suffix=True),
"moxfield": LineListFormat(),
```
to `deckformats/__init__.py`.

- [ ] **Step 5: Run the tests again**

Run: `uv run pytest tests/test_deckformats.py -v`
Expected: PASS

- [ ] **Step 6: Commit**

```bash
git add deckformats/
git commit -m "Add lossy text/Arena/Moxfield deck list import and export"
```

---

### Task 5: Widen the deck model — five zones, per-entry role/tags/locked/reason

**Files:**
- Modify: `decks.sv.jac`
- Test: `tests/decks_io_tests.jac` (new file)

**Interfaces:**
- Produces (used by Tasks 6–7):
  - `decks.DECK_ZONES: list[str] = ["commander", "companion", "main", "sideboard", "maybeboard"]`
  - `decks.Holds` edge gains `role: str = ""`, `tags: list[str] = []`, `locked: bool = False`, `reason: str = ""`
  - `decks.DeckCard` obj gains the same four fields, populated by `holdings`/`deck_view`
  - `decks.set_card_entry(deck: Deck, oid: str, zone: str, count: int, role: str = "", tags: list[str] = [], locked: bool = False, reason: str = "") -> int | None` — like `set_card_count` but also sets the four metadata fields; always *sets* (overwrites), never accumulates, and always operates on `oid`/`zone` regardless of whether `zone` is in the existing `ZONES` list (so `commander`/`companion`/`maybeboard` entries can be created through it even though `AddCard`/`SetCardCount`/`RemoveCard` stay restricted to `ZONES = ["main", "sideboard"]` exactly as today).
  - `decks.ValidateDeck` only ever builds `Entry` objects for `main`/`sideboard` holdings — `commander`/`companion`/`maybeboard` holdings are invisible to `check_entries`.

- [ ] **Step 1: Write the failing tests**

```jac
"""Walker-free tests for the mtgdeck/1 zone and entry metadata additions."""

import from decks { Holds, DECK_ZONES }

test "Holds defaults carry no role, tags, lock or reason" {
    h = Holds();
    assert h.role == "";
    assert h.tags == [];
    assert h.locked == False;
    assert h.reason == "";
}

test "DECK_ZONES covers all five mtgdeck/1 zones" {
    assert DECK_ZONES == ["commander", "companion", "main", "sideboard", "maybeboard"];
}
```

- [ ] **Step 2: Run it to see it fails**

Run: `uv run jac test tests/decks_io_tests.jac`
Expected: FAIL — `DECK_ZONES` (and the new `Holds` fields) do not exist yet.

- [ ] **Step 3: Modify `decks.sv.jac`**

- Add `glob DECK_ZONES: list[str] = ["commander", "companion", "main", "sideboard", "maybeboard"];` near the existing `glob ZONES: list[str] = ["main", "sideboard"];` (leave `ZONES` unchanged — it still governs `AddCard`/`SetCardCount`/`RemoveCard`).
- Add `role: str = ""`, `tags: list[str] = []`, `locked: bool = False`, `reason: str = ""` to the `Holds` edge's `has` list.
- Add the same four fields to `DeckCard`'s `has` list.
- In `deck_view`'s loop that builds `DeckCard` lines from `holdings(deck)`, pass `role=e.role, tags=e.tags, locked=e.locked, reason=e.reason` through to each `DeckCard(...)`.
- In `ValidateDeck.check`, inside the `for (e, c) in holdings(here)` loop, add `if e.zone not in ["main", "sideboard"] { continue; }` as the first line of the loop body, before building the `Entry`.
- Add `set_card_entry`, mirroring `set_card_count`'s structure exactly but also writing the four new fields on both the "create a new edge" and "update an existing edge" branches:

```jac
"""Set a card's full entry (count plus role, tags, locked and reason) in one
zone. Like set_card_count, but also carries the mtgdeck/1 entry metadata;
used by DeckImport. Always overwrites, never accumulates. Returns the count
before the change, or None if the card id is unknown."""
def set_card_entry(deck: Deck, oid: str, zone: str, count: int, role: str = "", tags: list[str] = [], locked: bool = False, reason: str = "") -> int | None {
    existing = holds_edge(deck, oid, zone);
    if existing is None {
        card = card_node(root, oid);
        if card is None {
            return None;
        }
        deck +>:Holds(count=count, zone=zone, role=role, tags=tags, locked=locked, reason=reason):+> card;
        return 0;
    }
    before = existing.count;
    existing.count = count;
    existing.role = role;
    existing.tags = tags;
    existing.locked = locked;
    existing.reason = reason;
    return before;
}
```

- [ ] **Step 4: Run the new test, and the type checker**

Run: `uv run jac test tests/decks_io_tests.jac`
Expected: PASS

Run: `uv run jac check *.jac`
Expected: all pass

- [ ] **Step 5: Run the existing suite for regressions**

Run: `uv run pytest tests && uv run jac test`
Expected: same pass counts as before this task (no behaviour change for existing `main`/`sideboard`-only decks).

- [ ] **Step 6: Commit**

```bash
git add decks.sv.jac tests/decks_io_tests.jac
git commit -m "Widen the deck model to mtgdeck/1's five zones and per-entry metadata"
```

---

### Task 6: `DeckExport` walker

**Files:**
- Create: `deck_io.sv.jac`
- Test: `tests/test_deck_io.py` (new file)

**Interfaces:**
- Consumes: `deckformats.get_format`, `ExportEntry`, `ExportDeck` (Task 2); `decks.Deck`, `decks.DeckAction`, `decks.holdings` (Task 5, pre-existing).
- Produces: `obj ExportResult { has format: str, content: str; }`; `walker:pub DeckExport(DeckAction) { has format: str = "mtgdeck1"; }` — reports one `ExportResult` on success, nothing if `format` is unknown or does not support export.

- [ ] **Step 1: Write the failing test**

```python
import json

from jaclang.runtimelib.testing import JacTestClient

from catalog import store


def _reports(resp):
    body = resp.json()
    assert body["ok"], body
    return body["data"]["reports"]


def _oracle_id(name: str) -> str:
    return next(c["oracle_id"] for c in store.search(name) if c["name"] == name)


def _new_deck(client, name="IO deck", format="modern") -> str:
    _reports(client.post("/walker/CreateDeck", json={"name": name, "format": format}))
    return _reports(client.post("/walker/ListDecks"))[0][-1]["_jac_id"]


def test_export_mtgdeck1_contains_every_card_in_the_right_zone(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": _oracle_id("Lightning Bolt"), "count": 4})
        client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": _oracle_id("Mountain"), "count": 20, "zone": "sideboard"})

        exported = _reports(client.post("/walker/DeckExport", json={"deck_id": deck_id, "format": "mtgdeck1"}))[0]
        doc = json.loads(exported["content"])
        assert doc["schema"] == "mtgdeck/1"
        assert {e["name"]: e["count"] for e in doc["zones"]["main"]} == {"Lightning Bolt": 4}
        assert {e["name"]: e["count"] for e in doc["zones"]["sideboard"]} == {"Mountain": 20}
    finally:
        client.close()


def test_export_with_an_unknown_format_reports_nothing(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        assert _reports(client.post("/walker/DeckExport", json={"deck_id": deck_id, "format": "nope"})) == []
    finally:
        client.close()
```

- [ ] **Step 2: Run it to see it fails**

Run: `uv run pytest tests/test_deck_io.py -v`
Expected: FAIL — no `deck_io` module / no `DeckExport` walker.

- [ ] **Step 3: Implement `deck_io.sv.jac`**

```jac
"""Deck import and export. Each format is a strategy looked up by name from
deckformats.FORMATS: the walkers below depend only on the DeckFormat
protocol, never on a specific format's parsing or rendering code.
"""

import from deckformats { get_format, ExportEntry, ExportDeck }
import from catalog.store { find_by_name, get_card as catalog_get_card }
import from decks { Deck, DeckAction, DeckView, holdings, deck_view, set_card_entry }

obj ExportResult {
    has format: str,
        content: str;
}

obj ImportResult {
    has deck: DeckView,
        unresolved: list[str] = [];
}

"""Export a deck in the given format (mtgdeck1, mtgjson, text, arena or
moxfield). Reports nothing for an unknown format or one that does not
support export."""
walker:pub DeckExport(DeckAction) {
    has format: str = "mtgdeck1";

    can export with Deck entry {
        try {
            fmt = get_format(self.format);
        } except ValueError {
            disengage;
        }
        export_deck = ExportDeck(
            name=here.name,
            format=here.format,
            entries=[
                ExportEntry(
                    oracle_id=c.oracle_id, name=c.name, count=e.count, zone=e.zone,
                    role=e.role, tags=e.tags, locked=e.locked, reason=e.reason
                )
                for (e, c) in holdings(here)
            ]
        );
        try {
            content = fmt.render(export_deck);
        } except NotImplementedError {
            disengage;
        }
        report ExportResult(format=self.format, content=content);
    }
}
```

(`ImportResult` and the `find_by_name`/`catalog_get_card`/`set_card_entry` imports are unused until Task 7, which lives in this same file — leave them in place now so Task 7 is a pure addition.)

- [ ] **Step 4: Run the test, and the type checker**

Run: `uv run pytest tests/test_deck_io.py -v`
Expected: PASS

Run: `uv run jac check *.jac`
Expected: all pass

- [ ] **Step 5: Commit**

```bash
git add deck_io.sv.jac tests/test_deck_io.py
git commit -m "Add the DeckExport walker"
```

---

### Task 7: `DeckImport` walker

**Files:**
- Modify: `deck_io.sv.jac`
- Test: `tests/test_deck_io.py` (append)

**Interfaces:**
- Consumes: everything already imported into `deck_io.sv.jac` by Task 6, plus `decks.set_card_entry` (Task 5).
- Produces: `walker:pub DeckImport(DeckAction) { has format: str = "mtgdeck1", text: str = ""; }` — reports one `ImportResult` on success (even if some lines were unresolved), nothing if `format` is unknown or does not support import.

- [ ] **Step 1: Write the failing tests**

```python
def test_export_mtgdeck1_then_import_round_trips(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": _oracle_id("Lightning Bolt"), "count": 4})
        client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": _oracle_id("Mountain"), "count": 20, "zone": "sideboard"})
        exported = _reports(client.post("/walker/DeckExport", json={"deck_id": deck_id, "format": "mtgdeck1"}))[0]

        imported = _reports(client.post("/walker/DeckImport", json={
            "deck_id": deck_id, "format": "mtgdeck1", "text": exported["content"],
        }))[0]
        assert imported["unresolved"] == []
        cards = {(c["name"], c["zone"]): c["count"] for c in imported["deck"]["cards"]}
        assert cards == {("Lightning Bolt", "main"): 4, ("Mountain", "sideboard"): 20}
    finally:
        client.close()


def test_import_flags_unresolved_lines_and_never_invents_a_card(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        result = _reports(client.post("/walker/DeckImport", json={
            "deck_id": deck_id, "format": "text",
            "text": "4 Lightning Bolt\n2 Flargle the Unreal\n",
        }))[0]
        assert result["unresolved"] == ["Flargle the Unreal"]
        assert [c["name"] for c in result["deck"]["cards"]] == ["Lightning Bolt"]
    finally:
        client.close()


def test_importing_a_new_list_replaces_what_was_there_before(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        client.post("/walker/AddCard", json={"deck_id": deck_id, "oracle_id": _oracle_id("Goblin Guide"), "count": 4})
        result = _reports(client.post("/walker/DeckImport", json={
            "deck_id": deck_id, "format": "text", "text": "4 Lightning Bolt\n",
        }))[0]
        assert [c["name"] for c in result["deck"]["cards"]] == ["Lightning Bolt"]
    finally:
        client.close()


def test_commander_zone_entries_do_not_count_toward_main_deck_legality(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client, format="modern")
        text = json.dumps({
            "schema": "mtgdeck/1", "name": "cmdr test", "format": "modern",
            "zones": {
                "commander": [{"name": "Lightning Bolt", "count": 1}],
                "main": [{"name": "Mountain", "count": 60}],
            },
        })
        result = _reports(client.post("/walker/DeckImport", json={"deck_id": deck_id, "format": "mtgdeck1", "text": text}))[0]
        assert result["unresolved"] == []
        view = _reports(client.post("/walker/GetDeck", json={"deck_id": deck_id}))[0]
        assert view["legal"] is True
        assert view["main_total"] == 60
    finally:
        client.close()


def test_import_with_an_unknown_format_reports_nothing(tmp_path):
    client = JacTestClient.from_file("main.jac", base_path=str(tmp_path))
    try:
        deck_id = _new_deck(client)
        assert _reports(client.post("/walker/DeckImport", json={"deck_id": deck_id, "format": "nope", "text": ""})) == []
    finally:
        client.close()
```

- [ ] **Step 2: Run them to see they fail**

Run: `uv run pytest tests/test_deck_io.py -v`
Expected: FAIL — no `DeckImport` walker.

- [ ] **Step 3: Implement `DeckImport` in `deck_io.sv.jac`**, appended after `DeckExport`:

```jac
"""Import a deck list, replacing the deck's current holdings entirely.
Lines or entries that don't resolve to a known card are listed in
`unresolved` and never added."""
walker:pub DeckImport(DeckAction) {
    has format: str = "mtgdeck1",
        text: str = "";

    can do_import with Deck entry {
        try {
            fmt = get_format(self.format);
        } except ValueError {
            disengage;
        }
        try {
            parsed = fmt.parse(self.text);
        } except NotImplementedError {
            disengage;
        }
        for (e, c) in holdings(here) {
            del e;
        }
        unresolved: list[str] = [*parsed.unparsed];
        for entry in parsed.entries {
            oid = "";
            if entry.oracle_id {
                if catalog_get_card(entry.oracle_id) is not None {
                    oid = entry.oracle_id;
                }
            } else {
                found = find_by_name(entry.raw_name);
                if found is not None {
                    oid = found["oracle_id"] as str;
                }
            }
            if not oid {
                unresolved.append(entry.raw_name);
                continue;
            }
            set_card_entry(here, oid, entry.zone, entry.count, entry.role, entry.tags, entry.locked, entry.reason);
        }
        report ImportResult(deck=deck_view(here), unresolved=unresolved);
    }
}
```

- [ ] **Step 4: Run the tests, and the type checker**

Run: `uv run pytest tests/test_deck_io.py -v`
Expected: PASS

Run: `uv run jac check *.jac`
Expected: all pass

- [ ] **Step 5: Commit**

```bash
git add deck_io.sv.jac tests/test_deck_io.py
git commit -m "Add the DeckImport walker: full-replace import that flags unresolved lines"
```

---

### Task 8: `deck_export`/`deck_import` MCP tools

**Files:**
- Modify: `mcp_server.jac`, `scripts/mcp_smoke.py`

**Interfaces:**
- Consumes: `deck_io.DeckExport`, `deck_io.DeckImport` (Tasks 6–7); `mcp_server.run_walker`, `mcp_server.first_report`, `mcp_server.plain` (pre-existing).
- Produces: MCP tools `deck_export(deck_id: str, format: str = "mtgdeck1") -> dict` and `deck_import(deck_id: str, format: str, text: str) -> dict`.

- [ ] **Step 1: Modify `mcp_server.jac`**

Add `import from deck_io { DeckExport, DeckImport }` alongside the existing `decks` import, then add, after `deck_validate`:

```jac
"""Export a deck: mtgdeck1 (lossless), mtgjson (lossless, export only), or text/arena/moxfield (lossy)."""
@server.tool()
def deck_export(deck_id: str, format: str = "mtgdeck1") -> dict {
    result = first_report(run_walker(DeckExport(deck_id=deck_id, format=format)));
    if result is None {
        return {"error": f"No deck with id {deck_id}, unknown format {format}, or {format} does not support export."};
    }
    return result as dict;
}

"""Import a deck list, replacing the deck's current cards. Accepts mtgdeck1,
text, arena or moxfield. Lines that don't resolve to a known card are listed
under "unresolved" and never added."""
@server.tool()
def deck_import(deck_id: str, format: str, text: str) -> dict {
    result = first_report(run_walker(DeckImport(deck_id=deck_id, format=format, text=text)));
    if result is None {
        return {"error": f"No deck with id {deck_id}, unknown format {format}, or {format} does not support import."};
    }
    return result as dict;
}
```

- [ ] **Step 2: Extend `scripts/mcp_smoke.py`**

In the `check("all eight tools from the issue are listed", ...)` call, add `"deck_export", "deck_import"` to the asserted set and update the label to `"all ten tools from the issue are listed"`.

Immediately after the existing block that switches the MCP-built deck to Standard and checks it's illegal (the `check("switching to Standard makes it illegal, with reasons", ...)` line), insert:

```python
exported = await call(session, "deck_export", deck_id=deck["id"], format="mtgdeck1")
check("export produces an mtgdeck/1 document", json.loads(exported["content"])["schema"] == "mtgdeck/1", exported)

reimported = await call(session, "deck_import", deck_id=deck["id"], format="mtgdeck1", text=exported["content"])
check("round-trip import resolves every entry", reimported["unresolved"] == [], reimported)
check("round-trip import keeps the same main total", reimported["deck"]["main_total"] == deck["main_total"], reimported)
```

- [ ] **Step 3: Run the type checker and the smoke test**

Run: `uv run jac check *.jac`
Expected: all pass

Run: `uv run python scripts/mcp_smoke.py`
Expected: every `PASS` line printed, ending `all checks passed`

- [ ] **Step 4: Run the full test suite**

Run: `uv run pytest tests && uv run jac test`
Expected: all pass (this re-runs `tests/test_mcp.py`, which drives the updated smoke script as a subprocess)

- [ ] **Step 5: Commit**

```bash
git add mcp_server.jac scripts/mcp_smoke.py
git commit -m "Add deck_export and deck_import MCP tools"
```

---

### Task 9: Export/import controls in the app

**Files:**
- Modify: `deck_detail.cl.jac`, `deck_detail.impl.jac`

**Interfaces:**
- Consumes: `deck_io.DeckExport`, `deck_io.DeckImport` (Tasks 6–7), called the same way the file already calls `decks` walkers (`root spawn Walker(...)` from an `impl` handler).
- Produces: no new interfaces for later tasks — this is the last code task.

- [ ] **Step 1: Add state and `sv import` in `deck_detail.cl.jac`**

Add `sv import from deck_io { DeckExport, DeckImport }` below the existing `sv import from decks { ... }` line. Add to `DeckDetail`'s `has` block: `exportFormat: str = "mtgdeck1"`, `exportText: str = ""`, `importFormat: str = "mtgdeck1"`, `importText: str = ""`, `unresolved: list[str] = []`. Add handler declarations alongside the existing ones: `async def runExport -> None;`, `async def setExportFormat(value: str) -> None;`, `async def setImportFormat(value: str) -> None;`, `async def runImport -> None;`.

- [ ] **Step 2: Add the JSX**

After the existing `<h2>Add cards</h2>` block (end of the returned `<section>`, before its closing tag), add:

```jsx
<h2>Export</h2>
<p>
    <select aria-label="Export format" value={exportFormat} onChange={lambda e: ChangeEvent { setExportFormat(e.target.value); }}>
        <option value="mtgdeck1">mtgdeck/1</option>
        <option value="mtgjson">MTGJSON Deck JSON</option>
        <option value="text">Plain text</option>
        <option value="arena">MTGA/MTGO</option>
        <option value="moxfield">Moxfield</option>
    </select>
    <button onClick={lambda _e: MouseEvent { runExport(); }}>Export</button>
</p>
<textarea readOnly={True} aria-label="Exported deck" value={exportText} style={{"width": "100%", "height": "8rem"}} />

<h2>Import</h2>
<p>
    <select aria-label="Import format" value={importFormat} onChange={lambda e: ChangeEvent { setImportFormat(e.target.value); }}>
        <option value="mtgdeck1">mtgdeck/1</option>
        <option value="text">Plain text</option>
        <option value="arena">MTGA/MTGO</option>
        <option value="moxfield">Moxfield</option>
    </select>
</p>
<textarea
    aria-label="Deck list to import"
    value={importText}
    onChange={lambda e: ChangeEvent { importText = e.target.value; }}
    style={{"width": "100%", "height": "8rem"}}
/>
<button onClick={lambda _e: MouseEvent { runImport(); }}>Import</button>
{<div role="status">
    <strong>Lines that didn't resolve</strong>
    <ul>{[<li key={line}>{line}</li> for line in unresolved]}</ul>
</div> if unresolved else None}
```

- [ ] **Step 3: Implement the handlers in `deck_detail.impl.jac`**

```jac
impl DeckDetail.setExportFormat(value: str) -> None {
    exportFormat = value;
}

impl DeckDetail.runExport -> None {
    result = root spawn DeckExport(deck_id=deckId, format=exportFormat);
    exportText = result.reports[0].content if result.reports else "";
}

impl DeckDetail.setImportFormat(value: str) -> None {
    importFormat = value;
}

impl DeckDetail.runImport -> None {
    result = root spawn DeckImport(deck_id=deckId, format=importFormat, text=importText);
    if result.reports {
        outcome = result.reports[0];
        deck = outcome.deck;
        unresolved = outcome.unresolved;
    }
}
```

- [ ] **Step 4: Type-check**

Run: `uv run jac check *.jac`
Expected: all pass

- [ ] **Step 5: Manual QA in the running app**

Run: `uv run jac start main.jac`, open http://localhost:8000, open a deck, add a few cards, click **Export** with `mtgdeck/1` selected, copy the text. Open a second deck, paste that text into the Import box with `mtgdeck/1` selected, click **Import**, and confirm the same cards and counts appear. Then try **Import** with `Plain text` selected and a pasted line naming a card that doesn't exist, and confirm it appears under "Lines that didn't resolve" and is not added to the deck. (Optionally drive this same check through `jac browse open localhost:8000`, `snapshot`, `click`, `fill`, `screenshot` instead of a hands-on pass.)

- [ ] **Step 6: Commit**

```bash
git add deck_detail.cl.jac deck_detail.impl.jac
git commit -m "Add export and import controls to the deck view"
```

---

### Task 10: Document the new files

**Files:**
- Modify: `README.md`

**Interfaces:** none (documentation only).

- [ ] **Step 1: Update the Layout section**

In the bulleted list under `### Layout`, add, in file order next to their siblings:
- after the `cards.sv.jac` line: `- schemas/mtgdeck-1.schema.json the published mtgdeck/1 deck document schema`
- after that: ``- `deckformats/` the deck import/export format strategies (mtgdeck/1, MTGJSON Deck JSON, plain/Arena/Moxfield text)``
- after the `decks.sv.jac` line: ``- `deck_io.sv.jac` the `DeckExport`/`DeckImport` walkers``

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "Document the mtgdeck/1 import/export files in the README"
```

---

## Self-Review

**1. Spec coverage** — Round trip (Task 7, `test_export_mtgdeck1_then_import_round_trips`); import flags unknown lines and never invents a card (Task 7, `test_import_flags_unresolved_lines_and_never_invents_a_card`, plus the Arena/text-level version in Task 4); schema published and exports validate against it (Task 1 + Task 2's `test_render_mtgdeck1_validates_against_the_schema`); lossless `mtgdeck/1` and MTGJSON export (Tasks 2–3); lossy text/Arena/Moxfield import+export (Task 4); zones + role/tags/locked/reason (Task 5); available in the app (Task 9) and as `deck_import`/`deck_export` tools (Task 8).

**2. Step scan** — Every code step carries an exact signature and the values the spec pins (schema JSON, zone names, format keys); test steps are full assertions; the two prose-described algorithms (`linelist` parse/render, Task 4; `DeckImport`'s resolution loop, Task 7) are accompanied by the exact regexes and are fully pinned by their tests.

**3. Type consistency** — `ParsedEntry`/`ExportEntry`/`ExportDeck`/`ParsedDeck` field names are defined once in Task 2 and used identically (same field names, same defaults) through Tasks 3–8; `set_card_entry`'s parameter order matches every call site in Task 7; `DECK_ZONES` is defined once in Task 5 and not redefined elsewhere.

**4. Review Focus** — all five lines above have an owning task and test, listed inline next to each.

**5. Proportion** — ten tasks for a feature touching eight existing files plus six new ones (schema, a four-module package, a new walker file, tests); each task's code is a handful of small functions or one walker, not a transcription of the whole feature.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-11-03-mtgdeck1-import-export.md`. Please review the plan. Which execution approach would you prefer?

- **Subagent-driven** — A fresh subagent implements each task and a fresh reviewer checks it before the next one starts, then a whole-branch review at the end. Most thorough; costs a fresh context per task and per review.
- **Native** — I implement every task myself in this session, the way this harness runs work, then one fresh reviewer on the most capable model checks the whole branch. Cheapest and fastest; no independent review until the end.

For this plan I recommend **subagent-driven**, because Tasks 5–8 share tight interface dependencies (the `Holds`/`DeckCard` fields from Task 5 and the `deckformats` registry from Tasks 2–4 both feed the two walkers in Tasks 6–7, which in turn feed the MCP tools in Task 8 and the UI in Task 9), and a shipped mistake in the zone/legality-filter decision (Task 5) or the replace-vs-merge import semantics (Task 7) would be awkward to unwind once the app and MCP layers are built on top of it — worth a fresh reviewer's eyes before each of those lands. Does the plan capture what you want, and which approach should we use?
