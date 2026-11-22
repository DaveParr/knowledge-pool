# Collections and quest lists count oracle cards, not printings

A user's collection (#174) records how many of each **oracle card** they have, the same unit as the catalogue (MTGJSON AtomicCards) and as deck holdings (`Holds` edges to `Card`). It does not record set, collector number, foil or condition. Everything the collection is for compares by oracle card: what a deck is missing, card search restricted to owned cards, importing a pasted list, and the quest list (#175), which is worked out from decks that are themselves counted by oracle card.

Printings are left out for now, not ruled out. So that adding them later is an extension rather than a remodel, the stored count must not assume one entry per oracle card. A count is keyed by (card, printing), with the printing blank for now, the way a `Holds` edge is keyed by (card, zone). Oracle-level totals are then a sum, and existing entries read as "printing unspecified" when printings arrive.

## Considered Options

- **Per printing from the start.** Needs a second catalogue source listing every printing (MTGJSON AllPrintings or Scryfall's default cards), a printing table in the SQLite build, a printing picker in the web page and MCP, and a printing-to-oracle mapping to compare with decks. Turned down for now: none of the uses in #174 or #175 need it, and it is several times the work.

## Consequences

Extending to printings later means: a `printings` table in the catalogue build (still a build output, so ADR 0001 stands); capturing the `(SET) 123` suffix that `deckformats/linelist.py` currently strips (`SET_SUFFIX_RE`); optional printing fields on the collection's count; and UI to pick a printing. Comparisons with decks stay oracle-level and do not change.
