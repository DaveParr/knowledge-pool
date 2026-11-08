# Context

Terms used in this codebase.

- **Deck holdings**: the cards a deck holds, as `Holds` edges (a count in one zone, plus entry metadata). They change only through `change_holding` (one card in one zone) or `replace_holdings` (the whole list) in `decks.sv.jac`, which check the zone, count and reason and log each count change as a `ChangeNote`.
- **Zone**: where in a deck a card is held: one of `ZONES` in `decks.sv.jac` (commander, companion, main, sideboard, maybeboard). Legality only counts main and sideboard.
- **Change note**: one logged change to a deck's holdings (card, zone, count before and after, and the reason). Kept on the `Deck` as its history.
