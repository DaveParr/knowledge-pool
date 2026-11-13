# The card catalogue stays in SQLite while the deck graph is in Postgres

The hosted app has a Postgres service for the deck graph, yet the card catalogue stays a read-only SQLite file built into the app's image. The catalogue is a build output, not state: it is derived whole from MTGJSON and Scryfall, nobody writes to it at run time, and a refresh replaces it by shipping a new image. Card search is written against SQLite's FTS5 (prefix matching, `bm25` ranking in `catalog/store.py`), so moving it to Postgres would mean rewriting search and its tests, loading a live database on every refresh, and a loaded database for every test run.

## Considered Options

- **Catalogue in the graph's Postgres.** One store instead of two. Turned down: Jac owns its Postgres schema and decks are reached through walkers, so the app could not join decks to cards in SQL, and the costs above buy nothing it can use.
- **Catalogue built at start-up onto a volume.** Turned down: it adds a volume to the app (a short outage on each deploy) and makes start-up depend on two outside sites being up.

Decided in "Decide: where it is hosted and where the graph is stored" (#96).
