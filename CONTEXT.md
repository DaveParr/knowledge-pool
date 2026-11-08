# Context

Terms used in this codebase.

- **Card catalogue** (`cards.sv.jac`): the one module that looks cards up, resolves card names and keeps `Card` nodes as a cache of the SQLite catalogue; `RefreshCards` updates that cache after a re-ingest. Only it calls `catalog.store`.
- **Deck holdings**: the cards a deck holds, as `Holds` edges (a count in one zone, plus entry metadata). They change only through `change_holding` (one card in one zone) or `replace_holdings` (the whole list) in `decks.sv.jac`, which check the zone, count and reason and log each count change as a `ChangeNote`.
- **Zone**: where in a deck a card is held: one of `ZONES` in `decks.sv.jac` (commander, companion, main, sideboard, maybeboard). Legality only counts main and sideboard.
- **Change note**: one logged change to a deck's holdings (card, zone, count before and after, and the reason). Kept on the `Deck` as its history.
- **Deck view** (`DeckView`, `deck_view` in `decks.sv.jac`): the one read of a deck that every deck walker reports: its card lines, totals, legality, recent history and main-deck mana analysis (mana profile and curve). A client gets the whole picture from the edit's own response; MCP `deck_analyze` is just the `mana` and `curve` part of it.
- **Card line** (`CardLine`, `card_lines.sv.jac`): one card in one zone of a deck, with its count, entry metadata and catalogue facts. `card_lines(deck)` in `decks.sv.jac` is the one place lines are built from the graph; legality (`check_lines`), the mana profile and the curve are pure functions over a deck's lines, and `DeckView.cards` is that list. It holds the one definition of a **land** (`is_land`: the front face is a land, so a spell // land double-faced card is a spell) and of the **main deck** (`main_deck`: the main zone).
