# S06 Commander Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A user can build a Commander deck and is told when it breaks Commander rules (100 cards, singleton, banlist, an eligible commander or legal pair, colour identity), and sees its Game Changer count with a bracket hint, in the web deck view and the MCP tools.

**Architecture:** The catalogue gains two columns (`leadership_skills`, `game_changer`) that flow through `Card` and `CardLine` like every other card fact. A new pure module `commander.sv.jac` holds the Commander domain facts as functions over `CardLine`s (who can lead, which pairs are legal, colour identity, Game Changers and the bracket hint), with no graph and no `Violation`. `legality.sv.jac` adds the `commander` format and turns those facts into `Violation`s: `check_lines` branches to `check_commander` when the format is Commander, and the per-card status/copy-limit loop is shared between both paths. `DeckView` gains an optional `game_changers` field that `deck_view` fills for Commander decks; the web deck view and the MCP deck tools show it.

**Tech Stack:** Jac (`jaclang` 0.16.7), Python 3.12 (`catalog/`, `scripts/`, pytest), SQLite catalogue built from MTGJSON AtomicCards, `jac test` for graph-free tests, `pytest` + `JacTestClient` for REST tests.

**Spec:** GitHub issues #38 (S06: Commander support, with the 2026-11-07 split decisions), #50 (S06a basics), #51 (S06b colour identity), #52 (S06c partner pairs), #53 (S06d Game Changers and bracket hint). All four sub-issues are in this branch.

## Global Constraints

- Format key `commander`, label `Commander` (MTGJSON legality key `commander`).
- Deck size: exactly 100, counting the commander zone and main deck together; companion and sideboard are not counted (#50).
- Singleton across the commander zone and main deck; basic lands and cards that say a deck can have any number (or up to N) of them are exempt (#50) — reuse `copy_limit_for`.
- Banned and not-legal come from MTGJSON `legalities.commander` (#50).
- Eligibility comes from MTGJSON `leadershipSkills.commander` (#50).
- Ingest stores `leadershipSkills` and `isGameChanger` as new catalogue columns (#50).
- Colour identity message shape, verbatim: `Counterspell (U) is outside Krenko, Mob Boss's identity (R)` (#51). Colourless commanders allow only colourless cards (#51). The companion is checked the same way as the main deck (#51).
- Supported pairs: Partner, Partner with [name] (only that partner), Friends forever, Choose a Background + a Background, Doctor's companion + a Time Lord Doctor (#52). Friends forever is printed as `Partner—Friends forever`; this plan treats every `Partner—<quality>` the same way (pairs only with the same quality), which covers Friends forever and the later Survivors / Character select / Father & son variants.
- Bracket hint from Game Changers only: 0 → bracket 1–2, 1–3 → bracket 3, 4+ → bracket 4+; labelled as a hint, not a full bracket rating (#53).
- Out of scope: Brawl, Oathbreaker and other variants; land/curve targets (#44); other bracket signals (#39); companion deck-building conditions; switching MTGJSON imports to `commander` (#73, not built).
- Dependencies stay pinned via `uv add`; no new dependency is needed.
- Before editing `.jac` files, run `uv run jac guide jac-core-cheatsheet` (AGENTS.md). Validate with `uv run jac check <file>`.

## Review Focus

- **A stale catalogue.** Someone pulls this branch with an old `data/catalog.sqlite`: startup must fail with the ingest command, not crash at query time, and existing `Card` nodes must pick up the new fields after `RefreshCards`. → Task 1's `test_catalogue_from_before_commander_fields_names_the_new_columns`.
- **The same card twice in the commander zone** (count 2). That is not a pair; it must report `copy-limit`, never be accepted as "Partner + Partner". → Task 5's `same card twice is not a pair` and deck `Thrasios twice`.
- **A deck set to Commander with no commander yet** (the normal state while building). It must give one clear `commander-count` violation and no identity noise for every coloured card. → Task 4's `no commander means no identity check`.
- **A double-faced or reminder-text partner line.** `Partner (You can have two commanders...)` and `Partner with Toothy, Imaginary Friend (When this...)` must parse as Partner / Partner with Toothy, and a card with "partner" elsewhere in its text must not. → Task 5's `partner ability reads the keyword line, not other text`.
- **Switching an existing 60-card deck to Commander and back.** Standard/Pioneer/Modern results must be unchanged, and `game_changers` must disappear when the format is not Commander. → Task 2 runs the existing `test_legality.py` unchanged; Task 6's `test_game_changers_only_on_commander_decks`.

---

## File Structure

- Modify `catalog/ingest.py` — two new `cards` columns, filled by `card_row`.
- Modify `catalog/store.py` — read the new columns into `leadership` and `game_changer`.
- Modify `cards.sv.jac` — `Card.leadership`, `Card.game_changer`, copied in `fill_card`.
- Modify `card_lines.sv.jac` — `CardLine.colour_identity`, `CardLine.leadership`, `CardLine.game_changer`.
- Modify `decks.sv.jac` — `card_lines` copies the three new fields; `DeckView.game_changers`; `deck_view` fills it.
- Create `commander.sv.jac` — pure Commander facts: zones, eligibility, partner abilities and pairing, colour identity, Game Changers and bracket hint.
- Modify `legality.sv.jac` — `commander` format, `check_commander`, shared per-card loop, Commander notes in `GetFormatRules`.
- Modify `mcp_server.jac` — `deck_validate` returns `game_changers`; `deck_brief`/`deck_markdown` mention it and the commander zone.
- Modify `deck_detail.cl.jac` (+ `deck_detail.css`) — commander zone heading already exists via zones; add the Game Changers line.
- Create `scripts/fixture_cards.py` — copy named cards and precon decks from a local AtomicCards / MTGJSON deck file into test fixtures.
- Modify `tests/fixtures/atomic_small.json` — new cards, plus `leadershipSkills`/`isGameChanger` on existing ones.
- Create `tests/fixtures/mtgjson_decks/DraconicRage_AFC.json`, `tests/fixtures/mtgjson_decks/TimeyWimey_WHO.json` — trimmed real precons (MTGJSON, MIT).
- Create `tests/fixtures/commander_decks.json` — the known legal/illegal Commander deck set.
- Create `tests/test_commander.py` — REST tests against that set, plus rules/MCP checks.
- Create `tests/commander_tests.jac` — graph-free tests of `commander.sv.jac` and `check_commander`.
- Modify `tests/old_catalog.py`, `tests/test_catalog_schema.py`, `tests/test_catalog.py`.
- Modify `CONTEXT.md`, `README.md` — new terms and test-set description.

---

### Task 1: Catalogue knows who can lead and which cards are Game Changers

**Files:**
- Create: `scripts/fixture_cards.py`
- Modify: `catalog/ingest.py` (SCHEMA, `card_row`, the `INSERT` placeholder count), `catalog/store.py` (`_COLUMNS`, `_card`)
- Modify: `cards.sv.jac` (`Card`, `fill_card`), `card_lines.sv.jac` (`CardLine`), `decks.sv.jac` (`card_lines`)
- Modify: `tests/fixtures/atomic_small.json`, `tests/old_catalog.py`, `tests/test_catalog_schema.py`, `tests/test_catalog.py`
- Create: `tests/fixtures/mtgjson_decks/DraconicRage_AFC.json`, `tests/fixtures/mtgjson_decks/TimeyWimey_WHO.json`

**Interfaces:**
- Produces: catalogue record keys `"leadership": dict[str, bool]` (MTGJSON `leadershipSkills`, `{}` when absent) and `"game_changer": bool`.
- Produces: `Card.leadership: dict[str, bool] = {}`, `Card.game_changer: bool = False`.
- Produces: `CardLine.colour_identity: list[str] = []`, `CardLine.leadership: dict[str, bool] = {}`, `CardLine.game_changer: bool = False`, filled by `decks.card_lines`.
- Produces: `scripts/fixture_cards.py` with two subcommands:
  - `cards --atomic PATH [--deck FILE ...] [NAME ...]` — adds each named card, and every card in each trimmed deck file, to `tests/fixtures/atomic_small.json`, keeping the fixture's existing per-face keys (`colorIdentity, identifiers, layout, legalities, manaCost, manaValue, name, subtypes, supertypes, text, type, types`) plus `leadershipSkills` and `isGameChanger` when MTGJSON has them. For cards already in the fixture it sets only `leadershipSkills`/`isGameChanger` from the source and leaves every other key alone (so `legality_decks.json` results don't move). Exits non-zero naming any name not found.
  - `precon SRC DEST` — writes a trimmed MTGJSON deck file: `{"meta": <src meta>, "data": {name, code, type, releaseDate, commander, companion?, mainBoard, sideBoard}}` where each card is `{"name", "count", "identifiers": {"scryfallOracleId"}}`.

- [ ] **Step 1: Write the fixture script and build the fixtures**

Download the two precons to the scratchpad (`curl -A "knowledge-pool-ingest/0.1 (+https://github.com/DaveParr/knowledge-pool)" https://mtgjson.com/api/v5/decks/<File>.json`), trim them with `precon`, then run `cards` with `--atomic` pointing at a local `AtomicCards.json.xz` (the main checkout has one at `/home/dave/Development/knowledge-pool/data/mtgjson/AtomicCards.json.xz`, MTGJSON 5.3.0+20261107; or run `uv run python -m catalog.ingest` first) and these names:

```
Krenko, Mob Boss; Sol Ring; Swamp; Anje Falkenrath; Jegantha, the Wellspring;
Lutri, the Spellchaser; Traxos, Scourge of Kroog; Thrasios, Triton Hero;
Tymna the Weaver; Pir, Imaginative Rascal; Toothy, Imaginary Friend;
Bjorna, Nightfall Alchemist; Sophina, Spearsage Deserter; Abby, Merciless Soldier;
Wilson, Refined Grizzly; Candlekeep Sage; Rose Tyler; Kenrith, the Returned King;
Rhystic Study; Demonic Tutor; Smothering Tithe; Mana Vault
```

plus `--deck` for both trimmed precons. Check by hand: `Chrome Mox` (already in the fixture) now has `"isGameChanger": true`; `Lightning Bolt`'s `legalities` are unchanged (`git diff` shows only added keys on existing cards).

- [ ] **Step 2: Write the failing tests**

In `tests/test_catalog.py`:

```python
def test_meta_records_mtgjson_version_and_date():
    ...
    assert meta["card_count"] == str(len(json.loads(FIXTURE.read_text())["data"]))  # was "35"

def test_commander_facts_are_stored():
    krenko = store.find_by_name("Krenko, Mob Boss")
    assert krenko["leadership"]["commander"] is True
    assert krenko["game_changer"] is False
    assert store.find_by_name("Lightning Bolt")["leadership"] == {}
    assert store.find_by_name("Rhystic Study")["game_changer"] is True
    assert store.find_by_name("Jace, the Mind Sculptor")["leadership"]["commander"] is False
```

In `tests/old_catalog.py` add `_BEFORE_COMMANDER` (= `_BEFORE_CARD_DETAILS` + the six #70 columns `power … faces`) and `drop_commander_fields(con)`. In `tests/test_catalog_schema.py`:

```python
def test_catalogue_from_before_commander_fields_names_the_new_columns(fixture_catalog):
    con = sqlite3.connect(fixture_catalog)
    drop_commander_fields(con)
    con.commit(); con.close(); store.reset()
    with pytest.raises(store.CatalogOutOfDate) as caught:
        store.check_current()
    assert "cards.leadership_skills" in str(caught.value)
    assert "cards.game_changer" in str(caught.value)
```

In `tests/cards_tests.jac` (or `test_deck_cards.py`, whichever already checks `fill_card` fields), assert a deck holding Krenko reports a card line with `colour_identity == ["R"]`, `leadership["commander"] == True`, `game_changer == False`.

- [ ] **Step 3: Run tests to verify they fail**

Run: `uv run pytest tests/test_catalog.py tests/test_catalog_schema.py -q`
Expected: FAIL — `KeyError: 'leadership'` and the out-of-date test not raising.

- [ ] **Step 4: Add the columns end to end**

SCHEMA, appended after `faces`:

```sql
    leadership_skills TEXT NOT NULL, -- JSON object, MTGJSON leadershipSkills, e.g. {"commander": true}; {} when none
    game_changer INTEGER NOT NULL    -- 1 when on the Commander Game Changers list (MTGJSON isGameChanger)
```

`card_row` reads both from the first face (`first.get("leadershipSkills") or {}`, `int(bool(first.get("isGameChanger")))`); the `INSERT` gets 18 placeholders. `store._card` maps them to `"leadership"` (JSON-decoded) and `"game_changer"` (`bool`). Then `Card` fields + `fill_card`, `CardLine` fields, and `decks.card_lines` copying `colour_identity`, `leadership` and `game_changer` from the `Card`.

- [ ] **Step 5: Run the whole suite**

Run: `uv run pytest tests -q && scripts/jac_test.sh && uv run jac check main.jac decks.sv.jac cards.sv.jac card_lines.sv.jac`
Expected: all pass (search-rank tests too — if a new card outranks an expected hit, fix the query in the test, not the ranking).

- [ ] **Step 6: Commit**

```bash
git add scripts/fixture_cards.py catalog/ cards.sv.jac card_lines.sv.jac decks.sv.jac tests/
git commit -m "Store commander eligibility and Game Changer flags in the catalogue (#50)"
```

---

### Task 2: Commander format basics — size, singleton, banlist, one eligible commander

**Files:**
- Create: `commander.sv.jac`
- Modify: `legality.sv.jac`
- Create: `tests/commander_tests.jac`

**Interfaces:**
- Consumes: `CardLine.leadership`, `CardLine.legal` (Task 1).
- Produces in `commander.sv.jac` (imports only `card_lines`):
  - `glob DECK_ZONES: list[str] = ["commander", "main"]` — counted for size and singleton.
  - `glob CHECKED_ZONES: list[str] = ["commander", "companion", "main"]` — checked for banned/not-legal (and identity in Task 4).
  - `def commanders(lines: list[CardLine]) -> list[CardLine]` — the commander-zone lines.
  - `def can_lead(line: CardLine) -> bool` — `line.leadership.get("commander", False)`.
- Produces in `legality.sv.jac`:
  - `FORMAT_LABELS["commander"] = "Commander"` (after `modern`, so "Use one of: standard, pioneer, modern, commander").
  - `glob FORMAT_RULES: dict[str, dict[str, int]] = {"commander": {"min_main": 100, "copy_limit": 1, "sideboard_max": 0}}`; `format_nodes` creates `Format(name=key, label=label, **FORMAT_RULES.get(key, {}))`. For Commander, `min_main` is the exact deck size over `DECK_ZONES`.
  - `def card_rule_violations(entries: list[CardLine], fmt: Format) -> list[Violation]` — the existing per-name banned / not-legal / copy-limit loop, moved out of `check_lines` unchanged.
  - `def check_commander(lines: list[CardLine], fmt: Format) -> list[Violation]`; `check_lines` returns it when `fmt.name == "commander"`.
  - `FormatRules.exact_size: bool = False` (True for Commander) and `def format_notes(fmt: Format) -> list[str]`.
- New violation rules: `deck-size`, `commander-count`, `commander-eligible` (plus existing `copy-limit`, `banned`, `not-legal`).

`check_commander` in this task:
1. `deck-size` when the sum of counts over `DECK_ZONES` ≠ `fmt.min_main`: `Deck has 99 cards counting the commander; Commander needs exactly 100.`
2. `card_rule_violations` over `DECK_ZONES` lines for copy-limit, and status over `CHECKED_ZONES` (call it once over `CHECKED_ZONES` lines but count copies over `DECK_ZONES` only — split the loop's two concerns with a parameter if needed; a companion copy never makes a `copy-limit`).
3. `commander-count` when the commander zone's count is 0: `A Commander deck needs a commander: put one in the commander zone.`; when it is 2 or more: `The commander zone holds 2 cards; Commander allows one.` (Task 5 changes this).
4. `commander-eligible` for each commander with `not can_lead(line)`, `card=name`: `Jace, the Mind Sculptor can't be your commander: MTGJSON doesn't list it as one (a legendary creature, or a card that says it can be your commander).`

- [ ] **Step 1: Write the failing tests** in `tests/commander_tests.jac`, with a `_line(name, zone, count, type_line, legal, leadership)` helper like `card_lines_tests.jac`'s, using `Format(name="commander", label="Commander", min_main=100, copy_limit=1, sideboard_max=0)`:

```
test "a 100-card deck with an eligible commander is legal" { ... check_commander(...) == [] }
test "deck size counts commander and main, not companion or sideboard" {
    # Krenko 1 + Mountain 98 main + 1 companion + 5 sideboard -> rules == ["deck-size"],
    # message == "Deck has 99 cards counting the commander; Commander needs exactly 100."
}
test "singleton counts commander and main; basics and any-number cards are exempt" {
    # 2x Lightning Bolt -> copy-limit "2 copies of Lightning Bolt; Commander allows 1."
    # 60x Mountain, 20x Relentless Rats (text "A deck can have any number of cards named Relentless Rats.") -> no copy-limit
}
test "banned is read from legal['commander'] across commander, companion and main" { ... rules include "banned" for a companion with {"commander": "Banned"}; a sideboard card with "Banned" adds nothing }
test "no commander is one commander-count violation" { ... }
test "a planeswalker that can't lead is commander-eligible, naming the card" { ... v.card == "Jace, the Mind Sculptor" }
```

- [ ] **Step 2: Run to verify they fail**

Run: `scripts/jac_test.sh tests/commander_tests.jac`
Expected: FAIL / ERROR — `check_commander` not defined.

- [ ] **Step 3: Implement `commander.sv.jac` and the `legality.sv.jac` changes above.** Update the `legality.sv.jac` module docstring (it says "60-card constructed formats"). `format_notes` for Commander returns, verbatim:
  - `"Exactly 100 cards, counting the commander zone and the main deck. Companion and sideboard are not counted."`
  - `"Singleton: one copy of each card across the commander zone and main deck. Basic lands, and cards that say a deck can have any number (or up to N) of them, are exempt."`
  - `"The commander must be able to lead per MTGJSON leadershipSkills.commander."`
  - `"Every card in the commander zone, companion and main deck must be legal in Commander according to MTGJSON."`
  
  Other formats keep today's four notes.

- [ ] **Step 4: Run tests**

Run: `scripts/jac_test.sh && uv run pytest tests -q && uv run jac check legality.sv.jac commander.sv.jac decks.sv.jac`
Expected: PASS, including the unchanged `tests/test_legality.py` (27 decks) and `test_api.py`'s "Use one of: standard" check.

- [ ] **Step 5: Commit**

```bash
git add commander.sv.jac legality.sv.jac tests/commander_tests.jac
git commit -m "Add the Commander format: 100 cards, singleton, banlist, eligible commander (#50)"
```

---

### Task 3: Commander deck test set, rules tool and MCP validate

**Files:**
- Create: `tests/fixtures/commander_decks.json`, `tests/test_commander.py`
- Modify: `README.md` (test-set paragraph), `CONTEXT.md` (Commander terms)

**Interfaces:**
- Consumes: `CreateDeckFromList` (`format: "text"`, `play_format: "commander"`), `GetDeck`, `GetFormatRules`, MCP `deck_validate` / `get_format_rules` (as `tests/test_mcp.py` calls them).
- Produces: `commander_decks.json` — a list of `{"name", "commander": {name: count}, "companion": {…}, "main": {…}, "sideboard": {…}, "legal": bool, "rules": [sorted rule codes]}`, or `{"name", "precon": "<file stem>", "legal", "rules"}` for a file in `tests/fixtures/mtgjson_decks/`. Later tasks append to it.
- Produces in `test_commander.py`: `_deck_text(deck: dict) -> str` (text-format list with `Commander`, `Companion`, `Deck`, `Sideboard` headers; a precon's `commander` and `mainBoard` map to `Commander` and `Deck`) and `_build(client, deck) -> dict` (creates via `CreateDeckFromList`, asserts `unresolved == []`, returns the `GetDeck` view).

- [ ] **Step 1: Write the deck set.** Entries for this task (fill `main` with basics to hit the stated totals):

| name | commander | other | legal | rules |
|---|---|---|---|---|
| Krenko mono-red | Krenko, Mob Boss | Lightning Bolt, Goblin Guide, Shock, Sol Ring, 95 Mountain | yes | [] |
| Precon: Draconic Rage | precon `DraconicRage_AFC` | | yes | [] |
| Anje any-number cards | Anje Falkenrath | 20 Relentless Rats, 9 Nazgûl, 7 Seven Dwarves, 63 Mountain | yes | [] |
| Kenrith with a companion and sideboard | Kenrith, the Returned King | 99 Mountain; companion Jegantha, the Wellspring (WUBRG, so it stays legal after Task 4); sideboard 10 Shock | yes | [] |
| 99 cards | Krenko | 98 Mountain | no | [deck-size] |
| 101 cards | Krenko | 100 Mountain | no | [deck-size] |
| Two Bolts | Krenko | 2 Lightning Bolt, 97 Mountain | no | [copy-limit] |
| Ten Nazgûl | Anje | 10 Nazgûl, 89 Mountain | no | [copy-limit] |
| Black Lotus | Krenko | Black Lotus, 98 Mountain | no | [banned] |
| No commander | — | 100 Mountain | no | [commander-count] |
| Jace leads | Jace, the Mind Sculptor | 99 Island | no | [commander-eligible] |

- [ ] **Step 2: Write the failing tests**

```python
def test_the_set_has_at_least_10_decks_of_each_kind_and_a_precon():
    assert len(DECKS) >= 10
    assert any(d["legal"] for d in DECKS) and any(not d["legal"] for d in DECKS)
    assert any("precon" in d for d in DECKS)

@pytest.mark.parametrize("deck", DECKS, ids=[d["name"] for d in DECKS])
def test_validator_agrees_with_known_commander_decks(client, deck):
    view = _build(client, deck)
    assert view["format"] == "commander"
    assert view["legal"] == deck["legal"], view["violations"]
    assert sorted({v["rule"] for v in view["violations"]}) == deck["rules"]

def test_format_rules_describe_commander(client):
    [rules] = _reports(client.post("/walker/GetFormatRules", json={"format": "commander"}))
    assert (rules["min_main"], rules["copy_limit"], rules["exact_size"]) == (100, 1, True)
    assert any("Exactly 100 cards" in n for n in rules["notes"])

def test_mcp_validate_reports_commander_violations(...):  # follow tests/test_mcp.py's setup
    # a 99-card Krenko deck -> {"legal": False, "violations": [{"rule": "deck-size", ...}]}
```

- [ ] **Step 3: Run to verify** — `uv run pytest tests/test_commander.py -q`. Expected: the set passes if Task 2 is right; if a deck fails, fix the code or a wrong fixture total, never loosen the assertion. (This task is test-first for the precon and REST path rather than for new code.)

- [ ] **Step 4: Docs.** README: one sentence that `tests/fixtures/commander_decks.json` holds known Commander decks, including real MTGJSON precons in `tests/fixtures/mtgjson_decks/` (trimmed, MIT), and that `scripts/fixture_cards.py` adds cards to the fixture; update "35 real cards". CONTEXT.md: add **Commander** (the format; deck = commander zone + main, exactly 100) and point to `commander.sv.jac`.

- [ ] **Step 5: Commit**

```bash
git add tests/fixtures/commander_decks.json tests/test_commander.py README.md CONTEXT.md
git commit -m "Test Commander rules against known decks and real precons (#50)"
```

---

### Task 4: Colour identity

**Files:**
- Modify: `commander.sv.jac`, `legality.sv.jac` (`check_commander`)
- Modify: `tests/commander_tests.jac`, `tests/fixtures/commander_decks.json`

**Interfaces:**
- Produces in `commander.sv.jac`:
  - `glob COLOURS: list[str] = ["W", "U", "B", "R", "G"]`
  - `def identity(lines: list[CardLine]) -> list[str]` — union of `colour_identity`, in WUBRG order.
  - `def identity_label(colours: list[str]) -> str` — `"colourless"` for `[]`, else the letters in WUBRG order joined (`"R"`, `"UR"`, `"WUBG"`).
  - `def commander_names(cmdrs: list[CardLine]) -> str` — `"Krenko, Mob Boss"`, or `"Thrasios, Triton Hero and Tymna the Weaver"` (zone order, which is name order).
- New rule `colour-identity`, `card=<card name>`, message `f"{name} ({identity_label(card)}) is outside {commander_names(cmdrs)}'s identity ({identity_label(identity(cmdrs))})"` — no trailing full stop, matching #51's example verbatim.

`check_commander` checks every `main` and `companion` line when the commander zone holds 1 or 2 cards (no check with 0 or 3+, so a half-built deck isn't buried in identity noise). With two commanders the identity is their union (#52 needs this; it works already for Task 5).

- [ ] **Step 1: Write the failing tests**

```
test "a card outside the commander's identity names the card and both identities" {
    # Krenko (["R"]) + Counterspell (["U"]) in main
    assert v.message == "Counterspell (U) is outside Krenko, Mob Boss's identity (R)";
    assert v.rule == "colour-identity" and v.card == "Counterspell";
}
test "a colourless commander allows only colourless cards" {
    # Traxos ([]) + Sol Ring ok; Lightning Bolt -> "Lightning Bolt (R) is outside Traxos, Scourge of Kroog's identity (colourless)"
}
test "the companion is checked like the main deck" { # Krenko + companion Lutri (["U","R"]) -> "(UR)" }
test "two commanders combine their identities" {
    # Thrasios (["G","U"]) + Tymna (["B","W"]) + Lightning Bolt ->
    # "Lightning Bolt (R) is outside Thrasios, Triton Hero and Tymna the Weaver's identity (WUBG)"
}
test "no commander means no identity check" { # 0 commanders + Counterspell -> only commander-count }
test "sideboard and maybeboard cards are not identity-checked" { ... }
```

Append to `commander_decks.json`: `Krenko with Counterspell` → `[colour-identity]`; `Traxos colourless` (Traxos, Sol Ring, 98 Wastes) → legal; `Traxos with a Bolt` → `[colour-identity]`; `Krenko with Lutri companion` → `[colour-identity]`.

- [ ] **Step 2: Run to verify they fail** — `scripts/jac_test.sh tests/commander_tests.jac` → FAIL (`identity` undefined).

- [ ] **Step 3: Implement** the functions and the `check_commander` step above. Add a `format_notes` line: `"Every card in the main deck and companion must fit inside the commander's colour identity (both commanders' together, for a pair)."`

- [ ] **Step 4: Run** — `scripts/jac_test.sh && uv run pytest tests/test_commander.py tests/test_legality.py -q` → PASS.

- [ ] **Step 5: Commit** — `git commit -m "Check Commander colour identity, naming the card and both identities (#51)"`

---

### Task 5: Partner pairs

**Files:**
- Modify: `commander.sv.jac`, `legality.sv.jac` (`check_commander`)
- Modify: `tests/commander_tests.jac`, `tests/fixtures/commander_decks.json`, `CONTEXT.md`

**Interfaces:**
- Produces in `commander.sv.jac`:
  - `def partner_ability(line: CardLine) -> str` — read from the card's rules-text lines (split `text` on `"\n"`, strip reminder text from `" ("` onward), first match wins:
    - `"Partner"` exactly → `"partner"`
    - `"Partner with <Name>"` → `"partner with:<Name>"`
    - `"Partner—<Quality>"` → `"partner—<Quality>"` (e.g. `"partner—Friends forever"`)
    - `"Choose a Background"` → `"choose a background"`
    - `"Doctor's companion"` → `"doctor's companion"`
    - otherwise `""`
  - `def is_background(line: CardLine) -> bool` — `"Background"` is a subtype on the front face's type line (after `"—"`).
  - `def is_time_lord_doctor(line: CardLine) -> bool` — front type line is a creature with subtypes `Time Lord` and `Doctor`.
  - `def pair_problem(a: CardLine, b: CardLine) -> str` — `""` when the two may be commanders together, else the reason (no trailing full stop). Legal when: both `partner`; `a` is `partner with:<b.name>` and `b` is `partner with:<a.name>`; both `partner—Q` with the same Q; one `choose a background` and the other `is_background`; one `doctor's companion` and the other `is_time_lord_doctor`. Reasons (pinned by tests):
    - a card with no ability: `"Krenko, Mob Boss has no partner ability"` (name the first card, in zone order, that has none)
    - partner with mismatch: `"Pir, Imaginative Rascal can only partner with Toothy, Imaginary Friend"`
    - choose-a-background without a Background: `"Wilson, Refined Grizzly needs a Background"`
    - doctor's companion without a Time Lord Doctor: `"Rose Tyler needs a Time Lord Doctor"`
    - any other mismatch (e.g. Friends forever + Survivors): `"Partner—Friends forever and Partner—Survivors don't pair"` (the two abilities as printed)
- `check_commander` changes:
  - `commander-count` only for 0 cards or 3+ (`The commander zone holds 3 cards; Commander allows one, or two that pair.`).
  - With exactly two commander *cards* (two lines, each count 1): if `pair_problem` is non-empty → `commander-pair` with message `f"{a.name} and {b.name} can't be commanders together: {why}."`.
  - `commander-eligible` skips a Background whose partner has `choose a background`.
  - A single line with count 2 is not a pair: the singleton `copy-limit` already reports it; do not also run `pair_problem`.

- [ ] **Step 1: Write the failing tests** (CardLines built from the real text of the fixture cards — copy their `text` and `type_line` from `atomic_small.json`):

```
test "partner ability reads the keyword line, not other text" {
    # Thrasios -> "partner"; Pir -> "partner with:Toothy, Imaginary Friend";
    # Bjorna -> "partner—Friends forever"; Wilson -> "choose a background";
    # Rose Tyler -> "doctor's companion"; Krenko -> ""; a card whose text says
    # "...creatures you control with partner..." on a non-keyword line -> ""
}
test "each pair kind is legal" { Thrasios+Tymna; Pir+Toothy; Bjorna+Sophina; Wilson+Candlekeep Sage; Tenth Doctor+Rose Tyler -> pair_problem == "" }
test "illegal pairs name the reason" {
    Krenko+Thrasios -> "Krenko, Mob Boss has no partner ability";
    Pir+Thrasios -> "Pir, Imaginative Rascal can only partner with Toothy, Imaginary Friend";
    Bjorna+Abby -> "Partner—Friends forever and Partner—Survivors don't pair";
    Wilson+Thrasios -> "Wilson, Refined Grizzly needs a Background";
    Rose Tyler+Krenko -> "Rose Tyler needs a Time Lord Doctor";
}
test "a Background can lead only beside a choose-a-Background commander" { Candlekeep Sage alone -> commander-eligible; with Wilson -> none }
test "same card twice is not a pair" { Thrasios count 2 in commander -> rules == ["copy-limit", ...size...], no commander-pair }
test "three commanders is commander-count" { ... }
test "the commander-pair message names both cards" {
    "Krenko, Mob Boss and Thrasios, Triton Hero can't be commanders together: Krenko, Mob Boss has no partner ability."
}
```

Append to `commander_decks.json`: legal — `Thrasios and Tymna`, `Pir and Toothy`, `Bjorna and Sophina (Friends forever)`, `Wilson and Candlekeep Sage`, `Precon: Timey-Wimey` (`precon: TimeyWimey_WHO`, The Tenth Doctor + Rose Tyler, 98 main); illegal — `Krenko and Thrasios` [commander-pair], `Pir and Thrasios` [commander-pair], `Bjorna and Abby` [commander-pair], `Candlekeep Sage alone` [commander-eligible], `Thrasios twice` (2 Thrasios in commander + 98 Island) [copy-limit], `Three commanders` [commander-count]. Each pair deck has 98 main cards (two commanders + 98 = 100), so "Deck size of 100 still includes both commanders" is covered; add `Thrasios and Tymna, 99 main` → [deck-size].

- [ ] **Step 2: Run to verify they fail** — `scripts/jac_test.sh tests/commander_tests.jac` → FAIL.

- [ ] **Step 3: Implement** the functions and `check_commander` changes. Update the `format_notes` eligibility line to: `"The commander must be able to lead per MTGJSON leadershipSkills.commander. Two commanders are allowed when they pair: Partner, Partner with (each other), Partner—<same quality> such as Friends forever, Choose a Background with a Background, or Doctor's companion with a Time Lord Doctor."` CONTEXT.md: add **Partner pair** pointing at `pair_problem`.

- [ ] **Step 4: Run** — `scripts/jac_test.sh && uv run pytest tests -q && uv run jac check commander.sv.jac legality.sv.jac` → PASS.

- [ ] **Step 5: Commit** — `git commit -m "Allow two commanders when they are a legal partner pair (#52)"`

---

### Task 6: Game Changers and bracket hint, in the deck view and MCP

**Files:**
- Modify: `commander.sv.jac`, `decks.sv.jac` (`DeckView`, `deck_view`), `mcp_server.jac` (`deck_validate`, `deck_brief`, `deck_markdown`), `deck_detail.cl.jac`, `deck_detail.css`
- Modify: `tests/commander_tests.jac`, `tests/test_commander.py`, `tests/test_mcp.py`, `CONTEXT.md`

**Interfaces:**
- Produces in `commander.sv.jac`:
  - `obj GameChangers { has cards: list[str] = [], count: int = 0, bracket_hint: str = ""; }` — `cards` sorted by name.
  - `def bracket_hint(count: int) -> str` — `0` → `"Bracket 1–2"`, `1..3` → `"Bracket 3"`, `4+` → `"Bracket 4+"` (en dash).
  - `def game_changers(lines: list[CardLine]) -> GameChangers` — distinct names of `game_changer` lines in `CHECKED_ZONES` (commander, companion, main); `count = len(cards)`.
- Produces in `decks.sv.jac`: `DeckView.game_changers: GameChangers | None = None`, set by `deck_view` only when `deck.format == "commander"`.
- MCP: `deck_validate` returns `"game_changers": view["game_changers"]` (null for non-Commander). `deck_brief` and `deck_markdown`, for a Commander deck, add `f"Game Changers: {n} ({', '.join(cards)}). Bracket hint from Game Changers only: {hint}."` (omit the parenthesised list when `n == 0`), and `deck_markdown` lists the `commander` zone before `main` with heading `### Commander`.
- Web: under the legality status in `DeckDetail`, when `deck.game_changers` is set: `Game Changers: 2 — Chrome Mox, Rhystic Study` and a second line `Bracket hint: Bracket 3 (from Game Changers only, not a full bracket rating)`.

- [ ] **Step 1: Write the failing tests**

```
test "bracket hint bands" {
    assert bracket_hint(0) == "Bracket 1–2";
    assert bracket_hint(1) == "Bracket 3";
    assert bracket_hint(3) == "Bracket 3";
    assert bracket_hint(4) == "Bracket 4+";
    assert bracket_hint(9) == "Bracket 4+";
}
test "game changers are listed by name from commander, companion and main" {
    # Rhystic Study main, Chrome Mox main, Mana Vault sideboard -> cards == ["Chrome Mox", "Rhystic Study"], count == 2
}
```

```python
def test_game_changers_on_commander_decks(client):
    view = _build(client, PRECON_TIMEY_WIMEY)
    assert view["game_changers"] == {**view["game_changers"], "cards": ["Farewell"], "count": 1, "bracket_hint": "Bracket 3"}

def test_four_game_changers_hint_bracket_4(client):
    # Kenrith + Rhystic Study, Demonic Tutor, Smothering Tithe, Mana Vault + basics to 100
    assert view["game_changers"]["bracket_hint"] == "Bracket 4+"

def test_game_changers_only_on_commander_decks(client):
    # build a Commander deck, SetDeckFormat to modern -> view["game_changers"] is None; back to commander -> set

# tests/test_mcp.py
def test_deck_validate_returns_game_changers(...):
    # Commander deck -> result["game_changers"]["count"] == 0 and bracket_hint == "Bracket 1–2"
    # Standard deck -> result["game_changers"] is None
```

- [ ] **Step 2: Run to verify they fail** — `scripts/jac_test.sh tests/commander_tests.jac; uv run pytest tests/test_commander.py tests/test_mcp.py -q` → FAIL.

- [ ] **Step 3: Implement** the module functions, `DeckView` field, MCP changes and the web line. In `deck_detail.cl.jac` add `sv import from commander { GameChangers }` beside the other `sv import`s.

- [ ] **Step 4: Run and look**

Run: `scripts/jac_test.sh && uv run pytest tests -q && uv run jac check main.jac decks.sv.jac frontend.cl.jac frontend.impl.jac deck_detail.cl.jac commander.sv.jac legality.sv.jac`
Expected: PASS.
Then `uv run jac start --dev main.jac` (with `KP_CATALOG` pointing at a real catalogue rebuilt by `uv run python -m catalog.ingest`), create a Commander deck, add Krenko to the commander zone and Rhystic Study + Counterspell to main, and check with `jac browse` that the violations list shows the colour-identity message and the Game Changers lines appear; switch the format to Modern and check they disappear.

- [ ] **Step 5: Commit**

```bash
git add commander.sv.jac decks.sv.jac mcp_server.jac deck_detail.cl.jac deck_detail.css tests/ CONTEXT.md
git commit -m "Show Game Changer count and bracket hint on Commander decks (#53)"
```

CONTEXT.md: add **Game Changer** and **bracket hint** ("from Game Changers only; not a full bracket rating").

---

## Done when

- `scripts/jac_test.sh`, `uv run pytest tests` and the CI `jac check` line all pass.
- #50–#53 acceptance boxes each map to a passing test: deck set ≥ 10 with two real precons (#50, #38), the Counterspell/Krenko message (#51), every pair kind and illegal pairs (#52), every bracket band (#53).
- A real catalogue rebuilt with `uv run python -m catalog.ingest` passes `store.check_current()`, and `RefreshCards` fills the new fields on existing `Card` nodes.
