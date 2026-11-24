# The web page's deck calls bypass Jac's server

The web page asks for deck data with `POST /walker/<name>` and `POST /function/<name>`, which Jac's server would normally answer. In the hosted app the front door answers them itself: it checks the session cookie and the request's `Origin`, runs the walker or function in process as the signed-in user, and replies in Jac's own format using Jac's serialiser. Jac's server only hands out the page and its static files. This gives one place that decides who the caller is and one code path that runs deck actions for both the web page and the claude.ai connector, and it means Jac's own sign-in, tokens and user endpoints are never used.

The walkers and functions the page calls are marked `:protect`, not left plain. The web client does not compile if they are plain. So Jac's server does carry those endpoints, but each refuses a call without a Jac token, no Jac token is ever issued, and Jac's server listens on `127.0.0.1` only.

## Considered Options

- **Forward the calls to Jac's server with a Jac token the front door writes for the user.** Keeps Jac's server as the thing that runs walkers. Turned down: it needs a signing secret shared between the two processes, a second notion of identity to keep in step with WorkOS, and two code paths for deck actions (forwarded for the page, in process for the connector). The in-process route was tested and works.
- **Leave the walkers plain, so Jac's server has no data endpoints at all.** This was the first plan. Turned down because it cannot work: the client build fails with E5082 for every plain walker or function the page imports.
- **Mark them `:pub`.** Turned down: Jac's server would then answer them for anyone who could reach it, with only the loopback address in the way.

## Consequences

- Every walker or function the page calls must be `:protect`, and must be a page-callable entry of the deck operations table (`deck_operations.jac`), from which the front door's table is derived (functions are listed in the deck-call endpoint's `FUNCTIONS`, `deck_call.jac`). Never `:pub`.
- The front door depends on two things inside Jac that are not a published interface: the reply envelope (`ok`, `type`, `data.result`, `data.reports`, `error`) and `jaclang.data.serializer.Serializer`. A Jac upgrade can change either, so the build needs a test that loads the page through the front door and reads a deck.
- The front door never forwards an `Authorization` header or any path under `/walker/`, `/function/`, `/user/` or `/sso/` to Jac's server. Doing so would open the token-protected endpoints to whoever holds a Jac token.
- The front door runs walkers itself, so it carries what Jac's server would have done for it: refusing unknown fields, and rolling back and re-running on a write conflict.
- The web client does not redirect on a 401. What the page does when the session has ended is the app's to design.

Decided in "Decide: how the web app and MCP run and share one front door on current Jac" (#101) and confirmed by "Test: the front door answering the web page's deck calls in process" (#104).
