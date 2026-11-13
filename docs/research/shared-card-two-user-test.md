# Decks under separate users holding one shared card node on current Jac

Test for issue #103, part of map #87. Run 2026-11-13. It settles the condition on "Decide: how a deck is owned and kept private" (#94).

## Short answer

- **The shared-root design holds.** Two signed-in users each attached a `Holds` edge from a deck under their own root to one `Card` on the shared root, and each read their own card, count and zone.
- **Nothing of one user's decks reached another user** through the shared `Card` or `Catalog`: not by traversal, edge listing, walker, `jobj` on ids, `printgraph`, `allroots()` or Jac's built-in `/graph` endpoints. The fallback (a copy of cards and formats per user) is not needed.
- **One exception sits below the language.** The raw anchor of a shared card (`card.__jac__.edges`) holds every user's edges, with deck names and counts, whoever asks. Only server code that reaches into `__jac__` sees it. The app must never read or serialise `__jac__`.
- **The app, acting as the guest user, should create and refresh the cards.** A card a user creates can be changed only by that user. A card the guest creates can be changed by the guest or the system identity, and by no signed-in user.
- **Viewing a shared deck needs a grant on the deck and on each of its `Holds` edges.** A grant on the deck alone shows the deck and its card names, but not counts or zones.

## How it was run

- The `jac` 0.39.2 binary (checksum matched), with its home and cache redirected to a scratch folder. Nothing in the repo or the real home folder changed.
- A small service app, `shared-card-two-user-test/main.jac`: `Catalog`, `Card`, `Format`, `Deck` and a `Holds` edge with `count` and `zone`, served by `jac run --no-dev -w 1` on the embedded Postgres.
- Three users registered over HTTP with passwords: Alice, Bob and Carol. Carol never owns a deck in the scenario under test, so she shows what a bystander sees.
- Every row below is a real HTTP call, driven by `shared-card-two-user-test/run*.py`. The in-process rows come from `inproc.jac`, run with `jac run --no-serve` beside the live server.
- The server was restarted between rounds; the first round's state read back the same afterwards.

Scenarios, each with its own catalogue, card and format hung under `root.shared`:

| Scenario | Created by | Opened with |
|---|---|---|
| G | guest (an anonymous `:pub` call) | `grant`: catalogue READ, card CONNECT, format READ |
| U | Alice | the same grants |
| R | guest | card READ only |
| N | guest or Alice | no grant |
| O | guest | no grant; `__jac_access__` on the node types returns the same levels as G |

## Answers to the ticket's questions

### Can both users attach the edge and read their own data

Yes, in G, U and O.

- Each user's `deck +>:Holds(count, zone):+> card` succeeded, and each read back their own card name, count and zone.
- A card needs **CONNECT**. With READ only (R) the attach was dropped without an error: HTTP 200 and a deck with no cards.
- An owner changed the count on their own edge, removed their own edge, and deleted their own deck. The card and the other user's edge were untouched each time.
- With no grant (N) a signed-in user does not see the node at all, even on the shared root. A node there stays closed until it is granted or its type declares `__jac_access__`.

### Can Bob reach Alice's deck, her edge, or tell that either exists

No. Bob's results on the shared card, with both decks attached:

| Bob's probe | Result |
|---|---|
| `[card <--]`, `[card <-:Holds:<-]`, `[card <-->]` | the catalogue and Bob's own deck only |
| `[edge card <--]`, `len([edge card <--])` | Bob's own `Holds` edge only; count 1 |
| walker spawned on the card, `visit [<--]` and `visit [edge <--]` | visits the catalogue, Bob's edge and Bob's deck |
| `jobj(alice_deck_id)`, `jobj(alice_edge_id)`, `jobj(alice_root_id)` | `None` each |
| `POST /walker/ReadDeck/<alice_deck_id>` | 404 |
| `printgraph(card)` | the card, Bob's deck and edge |
| `allroots()` then `[r --> [?:Deck]]` | Bob's decks only |
| the card returned from a function, or reported by a walker | its own fields only, no edges |
| `GET /graph/node?id=<card>` and `/graph/neighbors?id=<card>&dir=in` | Bob's deck and edge only; the counts are 1 |
| `GET /graph/node?id=<alice deck or root>` | 404 |
| Same probes from the catalogue | the shared root, the card and the format |

Carol, with no deck, saw the card with no incoming deck or edge. Alice saw only her own.

Three things Bob can learn or do:

- `allroots()` returns the root id of every user, so a signed-in user can count the users. Nothing under another root is readable.
- With CONNECT on a card, Bob can hang a node of his own off it. Only Bob sees it; Alice, Carol and the guest do not.
- `card.__jac__.edges`, the raw anchor, lists all three edges into the card for every caller, and the nested objects print Alice's deck name and her count. This is runtime internals, not a language read, and is reachable only from server code that asks for `__jac__`.

### Can a signed-in user change or delete a shared card or format

No. Bob tried to rename and delete the card (CONNECT) and the format (READ).

- By default each call returned HTTP 200. The value read back inside the same request was unchanged, and Alice saw no change. The server logged `Permission denied: field_write on Card[...]; required WRITE, have CONNECT`.
- With `JAC_STRICT_PERMISSIONS=1` set on the server, the same calls returned HTTP 500 `EXECUTION_ERROR` with that message. The READ-only attach in R also became a 500 instead of a silent drop.
- A user could not delete or change another user's `Holds` edge, including one shared with them at READ.

### Which identity can refresh the shared cards

| Cards created by | Who changed a card's field |
|---|---|
| guest (G, O) | the guest over an anonymous `:pub` call: yes. In process as the guest root: yes. In process as the system root: yes. Any signed-in user, over HTTP or in process: refused. |
| Alice (U) | Alice: yes. The guest: refused. Bob: refused. |

A write made in process by `inproc.jac` was visible through the running server at once.

Outside a served process `root.shared` is not the guest root. In `inproc.jac` it resolved to whichever root the script had set. A process that is not Jac's own server (the seed script, and the MCP server if it stays a separate process) must set the guest root itself, as `shared_graph.jac` `guest_root_id` does today, rather than rely on `root.shared`.

### Does `root.shared` still behave as the pinned source describes

Yes.

- From a signed-in request `root.shared` is the guest root, and the caller's level on it is CONNECT without any grant.
- An anonymous `:pub` call runs on that same root.
- Any signed-in user could hang a node there.

### Does a read grant on Alice's deck reach its edges and cards

Partly. `Jac.allow_root(deck, bob_root, READ)` on the deck alone:

- Bob read the deck's name, and `[deck ->:Holds:->]` returned the card nodes, so he saw which cards it holds.
- `[edge deck ->:Holds:->]` returned nothing, so he saw no counts or zones.
- From the card side, Alice's deck now appeared among the card's incoming nodes for Bob.

After a grant on each `Holds` edge as well, Bob read every count and zone. Then:

- Carol still saw nothing of the deck.
- Bob's rename of the deck and his change to an edge's count were refused.
- After `disallow_root` on the deck and edges, Bob was back to `no-such-deck` and saw nothing from the card side.

Grants are per node and per edge. A card added to a shared deck later has a new edge, which needs its own grant.

## What follows for the plan

- **Ownership (#94):** the condition is met. One `Catalog`, one set of `Card` nodes and one set of `Format` nodes on the shared root, with each deck's `Holds` edges under its owner.
- **Who creates the cards:** the app as the guest user, in process. Refresh then runs as the guest too.
- **How they are opened:** `Card` at CONNECT, `Catalog` and `Format` at READ. A type-level `__jac_access__` (scenario O) behaved the same as a `grant` on each node, and does not depend on a grant call at every place a card is created.
- **Refused writes:** the default is HTTP 200 with nothing changed. `JAC_STRICT_PERMISSIONS=1` turns them into errors.
- **Sharing (#95):** viewing means a grant on the deck and on each `Holds` edge, kept up as cards are added, or one read of the deck done by the app as the owner. Copying needs only what viewing needs.
- **Port:** `del [edge deck ->:Holds:->]`, the typed-edge delete the 0.39.2 guide documents, did nothing and raised no error. `for e in [edge deck ->:Holds:->] { del e; }` and `deck del --> card` both removed the edge.

## What was not tested

- More than one worker, or two requests writing at once.
- An external Postgres. Only the embedded one was used.
- Users signed in through WorkOS. The users were Jac password accounts.
- The real app's walkers. The test app copies their shape only.
- Whether a refused request under strict permissions rolls back everything else it wrote.
- Whether upstream treats this isolation as guaranteed behaviour.

## Files

- `shared-card-two-user-test/main.jac`, `jac.toml`: the test app.
- `shared-card-two-user-test/inproc.jac`: the in-process identity test.
- `shared-card-two-user-test/lib.py`, `run.py` to `run5.py`: the HTTP drivers, in the order they were run. Each takes the path of a file holding the server's port.
