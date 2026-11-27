# The phone app is a PWA, not a native app

Knowledge Pool is used mostly on a phone, and it should open like a phone app: from the home screen, full screen, with no browser chrome. We make the existing web app a Progressive Web App, using Jac's `[client.pwa]` table in `jac.toml`, which adds a manifest, a service worker and icons to the build. We do not build a native app with Jac's `mobile` app kind (React Native through `@jac/mobui`). One codebase serves the installed app and the desktop browser, and the desktop browser keeps working as before, now secondary to the phone.

Offline use is out of scope. The service worker caches the app shell and its static files, so an installed app with no signal shows a plain "You're offline" message instead of the browser's error page. It never caches deck data, the deck calls (`/walker/`, `/function/`), sign-in paths or page HTML: a cached deck could show stale counts after a change, or show one user's data after sign-out. We use Jac's built-in service worker if a spike shows it can be limited this way, and a minimal hand-written one if not.

## Considered Options

- **A native app with Jac's `mobile` kind.** Gives real native views, platform gestures and store distribution. Turned down: every screen would be rewritten in mobUI's vocabulary (no HTML, no CSS, so Pool block's stylesheets don't carry over), the app would need store releases, and the web app would still be needed for desktop, making two front ends. The app-like feel we want (standalone window, a tab bar, swiping between sections, a card view you swipe through) is reachable in the browser.
- **A PWA with offline support.** Caching decks and collections for reading without a signal. Turned down for now: it needs cache invalidation tied to every change, and care around sign-out, for a group that plays where there is signal.

## Consequences

- Real URLs matter more: a standalone app has no address bar and no browser back button, so every screen needs its own path and the app's own back control (ADR 0007).
- Sign-in must work inside the installed app on iOS and Android. AuthKit's redirect leaves the app's scope, and an installed iOS app can open it in a separate browser sheet with its own cookies. A spike on real phones comes before the shell is built, and the fix, if one is needed, belongs to the gatekeeper.
- When the session has ended, the page shows its own "Signed out" screen with a Sign in button that returns to the same page (the open question ADR 0004 left), instead of a redirect that could strand an installed app.
- The prompt to install the app is not Jac's automatic banner. It lives in one place, beside the instructions for adding Knowledge Pool to Claude as a connector.

Decided in the planning session for the installable phone app (November 2026), with a clickable prototype at `ui/mockups/navigation_prototype.html`.
