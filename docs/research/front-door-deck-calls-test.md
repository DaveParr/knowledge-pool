# The front door answering the web page's deck calls in process

Test for issue #104, part of map #87. Run 2026-11-13. It settles the condition on "Decide: how the web app and MCP run and share one front door on current Jac" (#101).

Everything below was **tested** unless marked **read**. Nothing in the repo or the real home folder changed.

## Short answer

- **It works, with one change to the plan.** A plain web handler in the MCP process answered every deck call the page makes, in process, as the signed-in user, and the page worked end to end in a browser. The fallback (forwarding to Jac's server with a Jac token) is not needed, and `create_jwt_token` was not run.
- **The change: the deck walkers cannot be left plain.** With them plain the web client does not compile. They must be marked `:protect`. Jac's server then does have those endpoints, but each refuses any call without a Jac token (401), nothing issues such a token, and the front door never forwards to them.
- **The page calls functions as well as walkers.** `POST /function/<name>` (`list_formats`, `search_cards`) needs the same treatment as `POST /walker/<name>`. #101 named only the walker path.
- **The reply format is Jac's own envelope, and Jac's own serialiser produces it** in one call.
- **The client sends nothing of its own that the front door must handle.** No `Authorization` header and no call to `/user/*` in the whole run.

## How it was run

- The `jac` 0.39.2 binary, with `HOME`, `XDG_CACHE_HOME` and `JAC_CACHE_HOME` pointed at a scratch folder, and Jac's embedded Postgres (Unix socket only, no port).
- A scratch copy of the repo at `70d37af` with `port-to-0.39.2.patch` from "Test: current Jac storing its graph in an external Postgres" (#105) applied (branch `research/external-postgres-test`).
- Two processes, as in #101:
  - Jac's server: `jac run --no-dev --host 127.0.0.1 -p 18761 -w 1`.
  - The front door: `front-door-deck-calls-test/front_door.jac`, run as `KP_WEB=0 jac run --no-serve front_door.jac` on port 18762. It imports the MCP server object from `mcp_server.jac` and adds web routes to it with the MCP SDK's `custom_route`, so `/mcp` and the web routes share one listener.
- Sign-in was a stand-in: `/test-sign-in?user=alice` sets an HttpOnly cookie naming the user. The real WorkOS session replaces it in the build.
- Browser: `jac browse` (headless Chromium), pointed only at the front door.

Not tested: the real WorkOS session cookie, what the page shows when the session ends while it is open, more than one Jac worker, MCP tools running as a user (they still used the guest root in this rig), and concurrent writes between an MCP tool and a web call.

## Results

### What the built web client sends

**Read** in the compiled client (`.jac/client/knowledge-pool/compiled/client_runtime_core.js`) and confirmed by the front door's request log:

| Call in the page's code | Request |
|---|---|
| `root spawn SomeWalker(...)` | `POST /walker/SomeWalker`, body is the walker's fields as JSON |
| a server function such as `search_cards(...)` | `POST /function/search_cards`, body is the arguments as JSON |

- Headers on both: `Content-Type: application/json` and `X-Jac-Endpoint` (a key naming the endpoint, such as `["","decks.jac","walker","ListDecks"]`). Walker calls also send `Accept: application/json`. The front door ignored `X-Jac-Endpoint` with no ill effect.
- `Authorization: Bearer <token>` is sent only if page script finds `jac_token` in `localStorage`. Nothing in this app sets it, and no request in the run carried the header. `localStorage` stayed empty.
- The browser adds `Origin` to every one of these calls, so #101's origin check works: a call with another origin got 403, the page's own calls passed.
- The cookie is HttpOnly: `document.cookie` was empty in the page, and the browser still sent it on every call.
- No request to `/user/*`, `/sso/*` or any other Jac path. The client has code for `/user/auth-policy`, `/user/login`, `/user/register` and `/user/logout`, but it runs only when the app calls Jac's sign-in helpers, which this app does not.
- The page's inline error reporter posts to `/cl/__error__` when a script error happens. None happened. The front door answers 404 for it, which the reporter ignores.
- The only 404 in the browser run was `/favicon.ico`.

### What reply the client expects

**Read** in the same file, and tested by the page working:

- A walker call needs HTTP 2xx and a JSON body with a `data` object; the page then reads `data.reports`.
- A function call needs HTTP 2xx, `ok` true, and `data.result`.
- Jac's own server sends one envelope for both:

```json
{"ok": true, "type": "response", "data": {"result": ..., "reports": [...]}, "error": null}
```

- Objects in `result` and `reports` are JSON objects with the fields plus four `_jac_*` keys (`_jac_type`, `_jac_id`, `_jac_archetype`, `_jac_type_id`). The page reads a deck's id from `_jac_id`.
- On a 401 the client does not redirect. With no stored token it returns an empty result to the page code (**read**; what the page then shows was not tested).

### Can a plain web handler in the MCP process produce it

Yes. The handler:

1. looks the walker class up by name in a fixed table (unknown name: 404),
2. builds it from the JSON body (wrong field: 422),
3. runs it in process on the signed-in user's root, with the roll-back and re-run from #105,
4. replies with `{"result": Serializer.serialize(walker, api_mode=True), "reports": Serializer.serialize(walker.reports, api_mode=True)}` inside the envelope above.

`Serializer` is `jaclang.data.serializer.Serializer`, the same call Jac's server makes (**read** in `jaclang/server/impl/server.impl.jac`, `_finalize_call_response`). The front door's replies matched Jac's own key for key. A function call is the same with the function's return value as `result` and an empty `reports`.

Jac's server has a ready-made class for all of this, `ExecutionManager.spawn_walker(walker_cls, fields, username)`, which also holds its conflict re-run policy (**read**, not tried). The rig used the app's own runner instead, as decided in "Decide: how an MCP tool call runs as the signed-in user" (#97).

### Does the page work end to end in a browser

Yes. Signed in as `alice` through the front door, in headless Chromium:

| Step in the page | Front door log |
|---|---|
| Page load | `/`, `/static/styles.css`, `/static/client.js` forwarded to Jac |
| Deck list shows | `function/list_formats`, `walker/ListDecks` |
| Create a deck | `walker/CreateDeck`, then `walker/ListDecks` |
| Open the deck | `walker/GetDeck` |
| Search "lightning bolt" (8 results) | `function/search_cards` |
| Add to main deck | `walker/AddCard` |
| Change the count | `walker/SetCardCount` |
| Change format to Modern | `walker/SetDeckFormat` |
| Open the export panel | `walker/DeckExport` |

Every call returned 200 "as alice" and the page showed the result each time. `CreateDeckFromList` (import) and `RemoveCard` were not clicked; `CreateDeckFromList` was called with curl and worked.

### Does it run as the signed-in user

Yes. Each stand-in user got a Jac user and root of their own.

- `alice` listed her two decks; `bob` listed none.
- `bob` calling `GetDeck` and `AddCard` with the id of alice's deck got the `no-such-deck` error both times.
- With no cookie: the page load was refused and a deck call got 401.

### Deck walkers left plain: the client does not compile

- With `:pub` removed from the walkers and data functions, Jac's server failed to build the page: error E5082, "Client code imports 'AddCard' from 'decks', but 'AddCard' has no client-side presence", once for each of the 11 walkers and functions the page uses. The compiler's own advice: mark it `:protect` or `:pub`.
- Marked `:protect`, the page built and ran as above.
- With `:protect`, Jac's server registers `/walker/<name>` and `/function/<name>` and answers 401 `UNAUTHORIZED` to a call without a Jac token. Called directly on port 18761 with no token, every one refused.
- So #101's sentence "Jac's server therefore has no data endpoints, and deck walkers stay plain" becomes: Jac's server has the endpoints, each closed without a Jac token; no Jac token is ever issued (registration off, `/user/*` and `/sso/*` answered 404 by the front door); and Jac's server listens on `127.0.0.1` only.
- Walkers the page does not call (`DeckAction`, `EditDeck`, `GetFormatRules`) stay plain and are not endpoints at all.

### Closed paths

Through the front door, signed in, each of these returned 404 and never reached Jac: `/docs`, `/openapi.json`, `/graph`, `/admin`, `/walkers`, `/functions`, `/user/auth-policy`, `/user/login`, `/sso/google/start`, `/cl/__error__`, `/healthz`.

### MCP and web on one listener

The same process answered `/mcp` (14 tools listed, `deck_list` called) while serving the web routes. 20 simultaneous `SetCardCount` calls on one deck all succeeded with no re-run: the rig runs each call to completion one at a time.

## For the build

- Mark every walker and function the page calls `:protect`, never `:pub`. A `:pub` one would be open on Jac's server to anything that reaches it.
- The front door needs a route for `/function/<name>` as well as `/walker/<name>`, each with a fixed table of what may be called.
- Add the token-protected paths to the test #101 already asks for: `/walker/*` and `/function/*` on Jac's server answer 401 without a token, and no path through the front door reaches them.
- The front door must not forward `Authorization` headers or anything under `/user/` or `/sso/`.
- Jac's server validates a call's body against the walker's fields and decodes special wire values (`_deserialize_wire_args`, **read**). The rig passed the JSON straight to the walker, which is enough for this app's plain string and number fields; the build should refuse unknown fields as the rig did (422).
- The rig's handlers block the event loop while a walker runs. Fine for a few users; the build should decide whether to run walkers on a thread.
- What the page shows when the session has ended (a 401 on a deck call) needs designing: the client will not redirect by itself.
- The rig lost its scratch folder to a machine restart before the session-ended check could be run in the browser; the logs quoted above are from the run before that.

## Files

- `front-door-deck-calls-test/front_door.jac`: the test front door.
- The port it ran in: `docs/research/external-postgres-test/port-to-0.39.2.patch` on branch `research/external-postgres-test`, then in `decks.jac`, `cards.jac` and `deck_io.jac` every `walker:pub` changed to `walker:protect` and `def:pub` to `def:protect` for `search_cards`, `catalog_info`, `find_card`, `resolve_names` and `list_formats`.
