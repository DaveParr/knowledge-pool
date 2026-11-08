# Knowledge Pool

Terms used in the code and issues.

## Glossary

- **Card catalogue** (`cards.sv.jac`): the one module that looks cards up, resolves card names and keeps `Card` nodes as a cache of the SQLite catalogue; `RefreshCards` updates that cache after a re-ingest. Only it calls `catalog.store`.
