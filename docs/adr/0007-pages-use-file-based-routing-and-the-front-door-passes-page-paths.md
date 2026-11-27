# Pages use Jac's file-based routing, and the front door passes page paths to Jac's server

The web app is one component today (`frontend.jac`) that swaps views with flags (`showCollection`, `openDeckId` and so on), so no view has a URL: refreshing loses your place, the back button leaves the app, and nothing can be linked to. We move every screen to Jac's file-based routing, Jac's recommended model: each screen is a file under `pages/` that returns `JsxPage`, `pages/layout.jac` is the shell that holds the tab bar (a side rail on desktop), and `main.jac`'s `app(children)` renders the router. `frontend.jac`'s flags go.

The routes:

| Path | Screen |
|---|---|
| `/` | redirects to `/decks` |
| `/decks`, `/decks/others` | your decks; other users' decks |
| `/decks/<id>` | a deck; `?tab=stats` or `?tab=changes` for its other sections |
| `/collection`, `/collection/<handle>` | your collection; another user's |
| `/quests`, `/quests/<handle>` | your quest list; another user's |

Mine and Others are separate paths, so back and shared links work. A deck's sections are a query string, so swiping between them does not pile up history.

Jac's server already answers any unreserved path with the page (its SPA fallback), but the front door does not pass those requests on: `is_page_path` (`gatekeeper.jac`) lets through only `/`, `/static/`, root scripts and stylesheets, and `/icons/`. Opening or refreshing `/decks/abc` would get a 404. The front door now forwards a `GET` or `HEAD` for any page path to Jac's server, for a signed-in browser, as it does for `/`.

## Considered Options

- **Manual routing** (`<Router>` and `<Routes>` declared in one file). Works, and keeps every route in one place. Turned down because Jac's guidance makes file-based routing the default and warns against mixing the two, and a `pages/` tree maps one-to-one onto the screens.
- **Hash routes** (`/#/decks/abc`). Would need no front door change. Turned down: it is not Jac's model, and it makes the URLs worse for the installed app and for sharing.
- **Listing each route in the front door.** Safer in principle, but every new screen would also need a gatekeeper change; the reserved prefixes are the stable part.

## Consequences

- This amends ADR 0004's rule that the front door forwards "the page and its static files and nothing else". It still never forwards a path under `/walker/`, `/function/`, `/user/` or `/sso/`, never forwards an `Authorization` header, and never forwards `/mcp`, the sign-in paths or `/healthz`, which keep their own routes. Any other `GET` or `HEAD` is the page. Jac's own non-page paths must stay switched off, since the front door no longer blocks them by path: `/docs` and `/graph` are off in `[serve]` today, and the ticket that changes `is_page_path` confirms nothing else (such as `/admin`) answers on the pinned Jac version, or adds it to the reserved list.
- A page path is subject to sign-in like `/` is: no session gets the sign-in redirect.
- The front door's tests gain deep-link cases: a deep path returns the page for a signed-in browser, and a reserved prefix is still refused.

Decided in the planning session for the installable phone app (November 2026). See ADR 0006.
