# A Jac user per WorkOS id, and the guest creating a card when a deck first includes it

Test for issue #110, part of map #87. Run 2026-11-13. It settles the two conditions on "Decide: how an MCP tool call runs as the signed-in user" (#97).

Everything below was **tested** unless marked **read**. Nothing in the repo or the real home folder changed.

## Short answer

- **A Jac user per WorkOS id works, and the fallback is not needed.** `UserManager.ensure_user_root("<WorkOS id>")` makes a user whose id is the WorkOS id, with no username and no password. Calling it again returns the same root. The runner ran walkers on that root. No Jac endpoint signed that user in.
- **Do not create it the way the guest is created.** `ensure_internal_user(id, "__no_password__")` stores `__no_password__` as a real password. Jac's `/user/login` accepted it and issued a token.
- **Both ways of having the guest create a card work.** In each, the user connected to the new card in the same call, the card was owned by the guest, no user could change it, and the guest could.
- **The two ways differ when a card is missed.** If the runner creates cards first and misses one, the walker creates it as the user: the deck holds a card the guest does not own and `RefreshCards` never reaches, with no error. Switching to the guest inside the card catalogue cannot miss a card.
- **Two users adding the same new card at the same moment get one card inside one process and two cards across two processes.** The runner's lock covers the first case. A unique index in Postgres closed the second in the test.
- **The guest changed a card a user's deck already held, in process with no user caller, and the user's deck showed the change.**

## How it was run

- The `jac` 0.39.2 binary (checksum matched), with `HOME`, `XDG_CACHE_HOME` and `JAC_CACHE_HOME` pointed at a scratch folder.
- Postgres 18 from Railway's image (`ghcr.io/railwayapp-templates/postgres-ssl:18`) in Docker, container `kp110-pg` on local port 55110, removed afterwards. `JAC_DB_URL` was set for every command.
- The app: the repo at `70d37af` with the scratch port from #105 applied (`external-postgres-test/port-to-0.39.2.patch`), then the changes in `jac-user-and-guest-card-test/cards-and-decks.patch`:
  - `apply_holding` and `deck_violations` look for cards and formats under `root.shared` instead of `root`.
  - `card_node` creates the card either as the caller or, with `KP110_MODE=switch`, as the guest.
  - A new card is opened to every user at CONNECT when it is created.
- The card catalogue: the 298-card test fixture.
- The runner is in `runner_and_cards.jac`. It is `run_walker` from the #105 port with the root passed in. It registers the guest root as `root.shared` with `Jac.set_shared_root_resolver`, and before any user call it has the guest create the `Catalog` and `Format` nodes and open them to every user at READ.
- Each step ran as its own `jac run --no-serve` process, so every result below was read back from Postgres by a fresh process.
- For sign-in attempts, Jac's own server ran in the copy on `127.0.0.1:18110` against the same database.

Not tested: real WorkOS tokens, more than one Jac worker, Railway.

## Part 1: a Jac user per WorkOS id

### Creating the user

| Call | Result |
|---|---|
| `ensure_user_root("user_01KP110ZZTESTA")`, first time | new user row with `user_id` equal to the WorkOS id, no identities, no credentials, role `user`; returns its root id |
| the same call again | the same root id, no second row |
| `get_root_id("user_01KP110ZZTESTA")` | the same root id |
| runner runs `CreateDeck`, `EditDeck`, `GetDeck`, `ListDecks`, `CreateDeckFromList` on that root | all worked; the decks were there in later processes |
| another user asks for that deck by id | `no-such-deck` |

`ensure_user_root` is the function Jac's own server uses for "a user another service signed in" (**read**, `jaclang/server/identity/impl/identity_storage.impl.jac`, `ensure_user_by_id`). If two calls race, the loser returns the winner's root (**read**).

### Can that user sign in through a Jac endpoint

No.

| Attempt on Jac's server | Result |
|---|---|
| `POST /user/login` as the WorkOS id with `__no_password__` or `__no_login__` | 401 `Invalid credentials` |
| `POST /user/login` with an empty password | 422 |
| `POST /admin/login` as the WorkOS id | 401 |
| `POST /user/forgot-password` for the WorkOS id | 200 with the same message it gives for any name; no emailer is configured, so nothing is sent |
| `um.authenticate(id, ...)` in process | `None` |

The user has no username, so a login by name finds nobody, and no password, so nothing could match. The only other way in is a token signed with Jac's own signing secret, which stays inside the app.

### What does not work: creating it the way the guest is created

- `ensure_internal_user("user_01KP110ZZTESTB", "__no_password__")` also makes one user and is harmless to repeat. But the second argument is stored as a real password: `POST /user/login` with that name and `__no_password__` returned 200 and a token.
- The same holds for the guest itself: `POST /user/login` as `__guest__` with `__no_password__` returned 200 and a token for the guest root. An anonymous call to a `:pub` walker already runs as the guest (#103), so this adds little, but it is one more reason Jac's own server is never published (#98).
- `__system__` with `__no_login__` was refused at `/user/login` (401) and at `/admin/login` (403, "Admin access required").

### A name clash to avoid

`get_root_id(x)` looks for a user whose id is `x` and, if there is none, for a user whose username is `x`.

- With registration left on, `POST /user/register` with the username `user_01KP110ZZTESTC` succeeded before any WorkOS user of that id had arrived. `get_root_id("user_01KP110ZZTESTC")` then returned that stranger's root.
- `ensure_user_root` looks up by id only. It made the right user, and afterwards `get_root_id` returned the right root.
- Registering the username `user_01ALICE` after the user with that id existed made a separate user and changed nothing for the first.

So the runner should take the root from `ensure_user_root` on every call and never from `get_root_id`, and registration stays off (already decided in #93).

### Also seen

Jac's server creates an `admin` user on first start and writes its one-time password to the log.

## Part 2: the guest creating a card

### Way 1: the runner creates the missing cards as the guest, then runs the walker as the user

Works. Alice's `EditDeck` with two new cards: both cards owned by the guest, both in her deck, in one tool call (two transactions: the guest's, then hers).

How the runner learns which cards are needed:

| Walker | Where the oracle ids come from |
|---|---|
| `EditDeck`, and `deck_create` with a card list (which calls `EditDeck`) | the `oracle_id` of each change |
| `AddCard`, `SetCardCount` | the walker's `oracle_id` field |
| `DeckImport`, `CreateDeckFromList` | the runner calls `resolve_list(format, text)` itself. It reads only the SQLite catalogue, so it is safe to call outside the walker, but the list is parsed and resolved twice. |

Tested for `EditDeck` and for `CreateDeckFromList` with a text list (two cards and one unknown name: the two cards were created by the guest, the unknown name came back as unresolved).

**What happens when the runner misses a card.** With no card created first, the walker's own `card_node` ran as the user:

- Default permissions: Jac refused the link from the `Catalog` to the new card, logged a warning and carried on. The deck showed the card and kept it. The card was owned by the user, not under the `Catalog`, and `RefreshCards` did not count it. Nothing told the caller.
- With `JAC_STRICT_PERMISSIONS=1`: the call failed with `Permission denied: edge_write on Catalog`, and nothing was written.

### Way 2: the card catalogue switches to the guest inside the walker

Works. `card_node` sets the context's acting root to the guest, creates the card, and puts the caller back in a `finally`:

```jac
def as_guest(f: any) -> any {
    ctx = Jac.get_context();
    prev = ctx._user_root;
    ctx._user_root = ctx._get_anchor(str(Jac.shared_root_id()));
    try { return f(); } finally { ctx._user_root = prev; }
}
```

- Bob's `EditDeck` with two new cards and one existing card: the two new cards owned by the guest, all three in his deck, one transaction.
- `CreateDeckFromList` as Bob: the same.
- **Roll back and re-run:** with a write conflict forced twice after the walker had run, the runner rolled back and re-ran twice. The result was one card, owned by the guest, and the deck correct.
- The owner is stamped when the node is first linked into the saved graph, from the acting root at that moment (**read**, `JacPersistence.save`), so the switch only has to cover the `cat ++> card` line.
- It relies on `_user_root`, a field of Jac's context with a leading underscore. Jac has a public way to create a node owned by another root (`Jac.save(node, owner=...)`), but it needs WRITE on that root (**read**), which users must not have on the guest root.

### In either way

| Check | Result |
|---|---|
| User connects to the new card in the same call | yes |
| A signed-in user changes the card's text | refused: nothing changed, warning in the log; with strict permissions a `PermissionError` |
| The guest changes the card's text, in process, no user caller | changed |
| Alice's and Bob's decks, read afterwards in fresh processes | both showed the guest's new text |
| `RefreshCards` run as the guest | updated every guest-owned card; decks showed the catalogue text again |

### Two users including the same new card at the same moment

- **Inside one process:** the runner holds one lock, so the second call runs after the first and finds its card. One card.
- **Across two processes** (two runners, each paused 3 seconds between looking for the card and creating it): **two cards**, both owned by the guest, with no conflict raised. It happened in both ways. Each deck holds its own copy, `card_node` picks the first it finds from then on, and `RefreshCards` updates both.
- **With a unique index** on the card's oracle id in Jac's `anchors` table, the same race gave one card: the second commit failed, the runner rolled back and re-ran, and found the first card.

  ```sql
  create unique index one_card_per_oracle_id on anchors ((props->'archetype'->>'oracle_id'))
    where arch_type like '%cards"].Card';
  ```

  The index is on a table Jac owns, so a Jac upgrade could break it.

The hosted design has one front door process (#101), so the two-process case arises only when two copies of it run at once, for example an old and a new container during a deploy.

## What the port needs, from this test

- Create users with `ensure_user_root(workos_id)` and use the root id it returns.
- Register the guest root with `Jac.set_shared_root_resolver`, so `root.shared` is the guest root in the front door as it is in Jac's server.
- Have the guest create the `Catalog` and `Format` nodes before the first user call and open them at READ. If a user gets there first, `catalog_node` creates a second `Catalog` owned by that user, because every user has CONNECT on the shared root.
- Open each new card at CONNECT when the guest creates it.
- Look for cards and formats under `root.shared`, not `root`.

## Files

- `jac-user-and-guest-card-test/runner_and_cards.jac`: the runner and every part 2 step.
- `jac-user-and-guest-card-test/users.jac`: the in-process part 1 checks.
- `jac-user-and-guest-card-test/cards-and-decks.patch`: the changes to `cards.jac` and `decks.jac`, on top of the #105 port patch.
