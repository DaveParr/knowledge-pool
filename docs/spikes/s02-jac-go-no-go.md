# S02: Jac go/no-go spike

**Decision: go, with the catalogue held in memory.** Jac's graph and walkers are fast enough for the synergy search, but Jac's persistence is far too slow to save the catalogue. So the catalogue graph is rebuilt in memory when the app starts (about 7 seconds), and only decks are saved.

Measured 2 Nov 2026 with jaclang 0.16.7 on Python 3.14.6, an Intel i5-9600K (6 cores) with 16 GB RAM, against MTGJSON 5.3.0+20261102 (35,408 oracle cards). Code is in `spike/`.

## Results against the exit criteria

| Criterion | Target | Result | Met |
|---|---|---|---|
| Full catalogue graph loads | under 5 minutes | 6.7 s in memory. Saving it would take about 40 minutes | yes, in memory only |
| FindSynergies on a 60-card deck | under 1 second | 224 to 282 ms (median of 5, three decks) | yes |
| Saved through Jac persistence or rebuilt in memory, with numbers | answered | rebuild in memory; numbers below | yes |

## The catalogue graph

`spike/synergy.jac` reads `data/catalog.sqlite` and builds, all in memory and not attached to `root`:

- 35,408 `Card` nodes, 6 `Theme` nodes and 5 `Role` nodes
- 16,824 `Enables`, 3,722 `PaysOff` and 10,286 `HasRole` edges from regular-expression rules over rules text

| Theme | Enablers | Payoffs |
|---|---|---|
| tokens | 4,316 | 1,016 |
| sacrifice | 860 | 290 |
| landfall | 332 | 236 |
| counters | 2,643 | 481 |
| graveyard | 815 | 1,232 |
| spells (every instant and sorcery enables it) | 7,858 | 467 |

Loading takes 6.7 s (reading SQLite, creating nodes and edges, and running the tagging rules). The process peaks at about 240 MB RSS.

## FindSynergies

The walker starts at a `Deck`, visits its cards over `Holds`, counts the themes they enable and pay off, steps to each theme, and from there to every card on the other side. A candidate scores for paying off a theme the deck enables (weight: the number of deck enablers) and for enabling a theme the deck pays off (half the number of deck payoffs). Cards already in the deck, or not legal in the deck's format, are skipped. Every suggestion keeps its score breakdown.

| Deck (Modern, 60 cards) | Median | Worst | Candidates scored |
|---|---|---|---|
| Mono-red burn (touches spells, the biggest theme) | 274 ms | 282 ms | 5,891 |
| Mono-black aristocrats (sacrifice, tokens) | 234 ms | 254 ms | 2,377 |
| Mono-green landfall | 224 ms | 236 ms | 2,351 |

Run it with `uv run jac run spike/bench.jac`.

The cost follows the size of the themes a deck touches, as the design doc expected. The burn deck reaches the 7,858-card spells theme and is the slowest. The suggestions look sensible for a spike (for example Judith, the Scourge Diva and Heirloom Auntie for aristocrats, and Retreat to Emeria for landfall). They ignore colour identity, and the tagging rules are rough. Both are Phase 2 work, not a reason to stop.

## Saving the catalogue through Jac persistence

`spike/persist_bench.jac` saves the first N cards through Jac's built-in persistence (the SQLite store that `jac start` uses) and times the whole run, commit included. Each run starts from an empty `.jac/data`.

| How cards are attached | 1,000 | 2,000 | 3,000 | 6,000 | 12,000 |
|---|---|---|---|---|---|
| Each card to `root` as it is made | 7.5 s | 28.6 s | 92 s | | |
| Built under one hub, hub attached once | 2.4 s | | 16.5 s | 63.0 s | |
| Under hub → buckets of 100 → cards | | | 16.9 s | 64.1 s | 272.4 s |

Each doubling costs about 4 times as much, so the time is quadratic in the number of saved nodes, whatever shape the graph has. Extrapolating the bucketed run to 35,408 cards gives about 40 minutes. A direct run of the hub layout on all 35,408 cards was stopped after 15 minutes. The database grows by about 2 MB per 1,000 cards.

The jac-scale plugin with MongoDB was not tested. Locally, Scale uses this same SQLite persistence.

**Answer: rebuild the catalogue in memory at start; save only decks.** Rebuilding takes about 7 s, against roughly 40 minutes to save it once, and a nightly MTGJSON refresh would mean saving it again.

## Other findings from S01, S03 and S04

- **Two Jac processes must not write one saved graph.** In S04 a second process opened the same `.jac/data` and shared root as a running `jac start`. Its new deck did not appear in the web app, and the web server's next write dropped that deck from the saved graph. So the MCP server and the web app run in one process.
- **S01 already keeps card data in SQLite** and creates a `Card` node only when a deck first uses a card. With an in-memory catalogue, a saved deck's `Holds` edges and the in-memory `Card` nodes need joining by `oracle_id`. A small index (dict by `oracle_id`, as `LoadedCatalog.by_name` does by name) is enough. The first real `find_synergies` tool should build its walker's start deck from the saved deck's oracle ids.
- **Typing at the Python boundary is noisy.** Every value from `sqlite3`, `json` or the MCP SDK needs an `as` cast or a `jac:ignore`, and graph references can't go inside f-strings. This costs time but does not block anything.
- **A walker that raises comes back as HTTP 200 with `ok: true`,** with the traceback in the payload, so walkers return no report rather than raising.

## What go means for the plan

- Keep Jac for the graph and walkers (S05 onwards).
- Load the catalogue graph in memory at server start, from `data/catalog.sqlite`, and keep it read-only.
- Keep saving only user data (decks, change history) through Jac persistence.
- Keep one process per saved graph. For hosted use, revisit with jac-scale and MongoDB, and measure again before relying on its persistence for anything big.
- If FindSynergies has to cover many more themes, or co-occurrence edges (the design's `CoOccurs`), measure again. The burn deck shows cost grows with theme size. Library mode or plain Python for the hot loop remains the fallback, as the design doc says.
