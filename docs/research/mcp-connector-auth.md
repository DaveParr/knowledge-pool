# How claude.ai connectors authenticate to a remote MCP server

Research for issue #88, part of map #87. Facts were checked on 2026-11-10.

## Short answer

A claude.ai connector that knows who each user is has to use OAuth: Claude calls the MCP endpoint, gets a `401`, discovers an authorization server from metadata the MCP server publishes, sends the user to that server to sign in, and then sends a bearer token on every request. The MCP server must check that each token was issued for it.

Google cannot be that authorization server directly. Google's published metadata has no client registration endpoint, does not support Client ID Metadata Documents, and does not accept public clients, so Claude cannot register itself there. Google's tokens are also issued for a Google client ID, not for the MCP server's URL, which the MCP specification requires the server to check.

So the tokens the MCP endpoint accepts have to come from an authorization server that sits between Claude and Google and uses Google only as the sign-in step. The facts leave two ways to provide one:

1. **Knowledge Pool issues its own tokens.** The pinned MCP Python SDK (`mcp` 2.3.0) ships the OAuth endpoints for this; the app supplies storage, the Google sign-in leg, the invite-list check and a consent page.
2. **A hosted identity service issues the tokens** (it offers Google sign-in and MCP-compatible client registration), and Knowledge Pool only verifies them. The SDK has a hook for the verification, but ships no ready-made verifier.

Choosing between the two is the decision for the later ticket.

## Terms

- **MCP server / resource server**: the Knowledge Pool MCP endpoint. In OAuth terms it is the "resource server": it accepts tokens, and does not have to issue them.
- **Authorization server**: the service that signs the user in and issues access tokens. It can be the same process as the MCP server or a separate service.
- **Protected resource metadata (RFC 9728)**: a small JSON document served by the MCP server that says "my URL is X, and tokens for me come from authorization server Y".
- **Dynamic Client Registration (DCR, RFC 7591)**: an endpoint on the authorization server where a client such as Claude registers itself and gets a client ID, with no human involved.
- **Client ID Metadata Document (CIMD)**: the newer alternative to DCR. The client ID is an HTTPS URL; the authorization server fetches that URL to read the client's name and redirect URIs. Nothing is registered or stored.
- **Public client**: an OAuth client with no secret. It proves itself with PKCE only.
- **PKCE**: a one-time secret the client creates per sign-in so that a stolen authorization code is useless to anyone else.
- **Resource indicator (RFC 8707)**: a `resource` parameter the client sends, naming the MCP server URL, so the token can be bound to that one server (its "audience").

## What the MCP authorization specification requires

The current specification is dated 2026-07-28. Source: https://modelcontextprotocol.io/specification/2026-07-28/basic/authorization and its sub-pages `authorization-server-discovery`, `client-registration` and `security-considerations`.

- Authorization is optional in MCP. When an HTTP server uses it, it should follow this specification. stdio servers should not; they take credentials from the environment.
- The MCP server must serve protected resource metadata that lists at least one authorization server. It must make the document discoverable either through a `WWW-Authenticate: Bearer resource_metadata="..."` header on its `401` responses, or at a well-known URL (`/.well-known/oauth-protected-resource/<mcp path>`, then `/.well-known/oauth-protected-resource`).
- The authorization server must implement OAuth 2.1, must publish its own metadata (RFC 8414 or OpenID Connect Discovery), and that metadata must include `code_challenge_methods_supported`, or clients must refuse to proceed. All its endpoints must be HTTPS.
- Clients get a client ID in one of three ways, in this priority order: a pre-registered ID, a Client ID Metadata Document (when the authorization server advertises `client_id_metadata_document_supported`), then Dynamic Client Registration (when it advertises `registration_endpoint`). CIMD is a "should support". DCR is now marked deprecated and kept for backwards compatibility.
- Clients must use PKCE with `S256`, and must send the `resource` parameter naming the MCP server on both the authorization and the token request.
- The MCP server must validate every token, must accept only tokens issued for itself as audience, and must answer invalid or expired tokens with `401`. It must not accept or pass on other tokens.
- The token goes in the `Authorization: Bearer` header on every HTTP request, never in the URL.
- For public clients the authorization server must rotate refresh tokens. Short-lived access tokens are recommended.
- An MCP server that acts as a go-between to a third-party authorization server using one fixed client ID there (the shape of "our server in front of Google") must get the user's consent for each registered client before forwarding to the third party. This prevents the "confused deputy" attack, in which an attacker reuses a consent the user already gave Google to get a code for their own client.
- The 2026-07-28 revision adds a check of the `iss` parameter on the authorization response (RFC 9207). Authorization servers should send it.

## What Anthropic's connector documentation requires

Source: https://claude.com/docs/connectors/building/authentication.md unless another URL is given. The page says the same authentication infrastructure backs claude.ai, Claude Desktop, Claude mobile, Cowork and Claude Code.

**Authentication types.** Claude supports OAuth with DCR, OAuth with CIMD, and no authentication, all by default. A fixed credential sent as a request header is in beta for a limited set of organizations, is entered once by an organization Owner, and is shared by every member, so it cannot identify which user is calling. A machine-to-machine `client_credentials` grant is not supported.

**Transport.** Streamable HTTP. The older HTTP+SSE transport still works but is being deprecated. Source: https://claude.com/docs/connectors/building.md

**Specification versions.** Claude follows the 2025-03-26, 2025-06-18 and 2025-11-25 authorization specifications. The page does not list 2026-07-28. Source: https://claude.com/docs/connectors/building.md

**Starting sign-in.** Claude starts sign-in only on an HTTP `401`. It ignores a `WWW-Authenticate` header on a `200`, and a tool result that says "please sign in" does nothing. The header should carry `resource_metadata`; if it does not, Claude probes the two well-known URLs on the MCP server's origin.

**Discovery.**
- The `resource` field of the protected resource metadata must equal the MCP server URL exactly as the user typed it into Claude, including the path.
- Claude uses only the first entry of `authorization_servers`.
- The authorization server may be on a different host from the MCP server, but both must be reachable from Anthropic's egress range.
- Claude caches both metadata documents for about five minutes, shared across all users of the same URL. Source: https://claude.com/docs/connectors/building/lazy-authentication.md

**How Claude identifies itself.** In the "Add custom connector" dialog the user picks one of: "Use Claude's published identity" (CIMD, recommended), "Register automatically" (DCR), or "Use your own OAuth client" (a client ID, and optionally a secret, that the user registered with the server). Authentication settings cannot be changed after the connector is added; the user must remove it and add it again. Source: https://claude.com/docs/connectors/custom/add-unlisted.md
- Claude normally uses CIMD only when the authorization server metadata has both `"client_id_metadata_document_supported": true` and `"none"` in `token_endpoint_auth_methods_supported`. Otherwise it falls back to DCR, which needs a `registration_endpoint`.
- With DCR, Claude registers a new client on every fresh connection, as a public client.
- With CIMD, the authorization server should show the host of the client ID URL on its consent screen, not the self-declared client name.

**PKCE and scopes.** Claude always sends an `S256` PKCE challenge. It requests the scopes named in the `401` header, or else those in the protected resource metadata, and adds `offline_access` when the authorization server lists it, to get a refresh token.

**Callback URLs (redirect URIs).**
- Hosted apps (claude.ai on the web, Desktop, mobile, Cowork): exactly `https://claude.ai/api/mcp/auth_callback`.
- Claude Code: a loopback address on a port that changes per session, such as `http://localhost:3118/callback`. Claude Code's own Client ID Metadata Document is at https://claude.ai/oauth/claude-code-client-metadata (fetched live: it declares `http://localhost/callback` and `http://127.0.0.1/callback`, public client). The authorization server must match these with the port ignored.

**Token endpoint.**
- It must accept `application/x-www-form-urlencoded`. The registration endpoint takes JSON.
- Claude refreshes on a `401` and also up to five minutes before expiry.
- A dead refresh token must be answered with `invalid_grant`.
- Refresh tokens should be rotated for public clients, with the new one returned in the same response.

**Time limits.** Claude waits 10 seconds for discovery, registration and token endpoints and 30 seconds for a refresh. A slower answer counts as a failure. A tool call may take 240 seconds on claude.ai and Desktop. Source for the tool limit: https://claude.com/docs/connectors/building.md

**Source IPs.** "Claude reaches your server from Anthropic's infrastructure" (https://claude.com/docs/connectors/building/testing.md), so a claude.ai connector needs a public HTTPS URL. The authentication page gives the outbound range as `160.79.104.0/21`. Anthropic's IP reference lists two outbound IPv4 ranges, `160.79.104.0/21` and `153.61.208.0/20`, and says they will not change without notice (https://platform.claude.com/docs/en/api/ip-addresses). Discovery and token requests to the authorization server come from the same range. The user's browser, not Anthropic, makes the request to the authorization endpoint, so that endpoint and the Google sign-in pages see the user's own IP.

**Plans.** Custom connectors can be added on every plan, including Free (one custom connector). On Team and Enterprise an Owner adds it and each member then connects with their own account. Source: https://claude.com/docs/connectors/custom/add-unlisted.md

**Request checks.** The MCP SDKs reject unknown `Host` headers, and the testing page warns that strict `Origin` checks reject Anthropic's requests. `clientInfo` in the MCP handshake is unauthenticated and must not feed an authorization decision. Source: https://claude.com/docs/connectors/building/testing.md

### Claude Code over HTTP

Source: https://code.claude.com/docs/en/mcp

- Claude Code connects from the user's own machine, not from Anthropic's cloud (the lazy-authentication page says "Claude Code connects to a `localhost` server directly"). Anthropic's IP ranges therefore do not apply to it.
- It runs the same OAuth flow, started with `/mcp` or `claude mcp login <name>`, and supports both DCR and CIMD. It stores and refreshes tokens itself.
- It also accepts a fixed header: `claude mcp add --transport http <name> <url> --header "Authorization: Bearer <token>"`. With such a header it does not fall back to OAuth. This gives Claude Code a non-OAuth path that claude.ai does not have for ordinary accounts.
- A pre-registered client can be supplied with `--client-id`, `--client-secret` and `--callback-port`; the redirect URI to register is then `http://localhost:PORT/callback`.
- A claude.ai connector also appears inside Claude Code for a signed-in user, so a working claude.ai connector covers Claude Code without a second setup.

## What the pinned MCP Python SDK provides

`uv.lock` pins `mcp` 2.3.0, with `pyjwt` 2.15.1 and `cryptography` installed as its dependencies. Paths below are under `.venv/lib/python3.14/site-packages/mcp/`.

`MCPServer(...)` takes `auth=AuthSettings(...)` plus exactly one of `token_verifier` or `auth_server_provider` (`server/mcpserver/server.py`, lines 249-263). Knowledge Pool's `mcp_server.jac` starts the HTTP transport with `server.run_streamable_http_async(...)`, which builds the same app, so auth set on the `MCPServer` applies there. `mcp_server.jac` passes neither today.

**In both modes** (`server/auth/middleware/bearer_auth.py`, `server/auth/routes.py`, `server/auth/settings.py`):
- The whole MCP endpoint is wrapped. A request with no valid token gets `401` with `WWW-Authenticate: Bearer error="invalid_token", ..., resource_metadata="<url>"`. A token missing a required scope gets `403` with `insufficient_scope`. This includes `initialize` and `tools/list`, so nothing reaches a tool without a token.
- When `AuthSettings.resource_server_url` is set, the SDK serves the protected resource metadata at `/.well-known/oauth-protected-resource<mcp path>`, listing `AuthSettings.issuer_url` as the only authorization server.
- With `validate_token_resource=True`, a token is refused unless its `resource` equals `resource_server_url`. Leaving the setting unset skips the check and logs a deprecation warning.
- Inside a tool, `mcp.server.auth.middleware.auth_context.get_access_token()` returns the verified `AccessToken`, whose `subject` field is where the user's identity travels. This is the hook for running a walker on that user's graph root instead of the shared guest root.
- `@server.custom_route(...)` adds routes that skip the token check, intended for things like an OAuth callback.

**Verify-only mode: `token_verifier`** (`server/auth/provider.py`, class `TokenVerifier`). The app supplies one async method, `verify_token(token) -> AccessToken | None`. The package contains no ready-made verifier: there is no JWT or introspection implementation in `server/auth/` (the docstrings point to one in the SDK's examples, which are not installed). The app would write it, for example with PyJWT against the issuer's published keys, checking signature, issuer, expiry and audience.

**Issuer mode: `auth_server_provider`** (`server/auth/provider.py`, class `OAuthAuthorizationServerProvider`; handlers in `server/auth/handlers/`). The SDK serves `/.well-known/oauth-authorization-server`, `/authorize`, `/token`, and optionally `/register` (DCR) and `/revoke`. It validates requests, checks redirect URIs, verifies the PKCE `S256` challenge, authenticates clients, and carries the `resource` value through to the tokens. The app implements the provider's methods: store and load clients, authorization codes, access tokens and refresh tokens; and `authorize()`, which returns the URL to send the user to next. The docstring of `authorize()` describes exactly the "redirect to a third-party provider, then come back and issue our own code" pattern needed for Google.

Limits of issuer mode in 2.3.0, read from the source:
- The metadata it publishes lists `token_endpoint_auth_methods_supported` as `client_secret_post` and `client_secret_basic` only, and never sets `client_id_metadata_document_supported` (`server/auth/routes.py`, `build_metadata`). Under Claude's rule above, Claude will therefore use DCR against it, not CIMD. DCR must be switched on with `ClientRegistrationOptions(enabled=True)`.
- There is no server-side CIMD support: nothing fetches a client ID URL. The only mention is a field on the metadata model (`shared/auth.py`, line 229).
- The registration handler does accept public clients (`token_endpoint_auth_method: "none"`), which is what Claude registers as.
- Redirect URIs are matched exactly (`shared/auth.py`, `validate_redirect_uri`), with no port-agnostic loopback rule.
- The SDK provides no storage, no consent page, no Google integration and no token format. Because DCR creates a new client per fresh connection, the client store grows over time.

## How Google sign-in can sit behind it

Google's live metadata (https://accounts.google.com/.well-known/openid-configuration, fetched 2026-11-10) has no `registration_endpoint` and no `client_id_metadata_document_supported`, and lists only `client_secret_post` and `client_secret_basic` as token endpoint methods. It does support `S256` PKCE. Google OAuth clients are created by hand in the Google Cloud Console, and redirect URIs must match exactly (https://developers.google.com/identity/protocols/oauth2/web-server).

**Google as the authorization server directly.** The only route is "Use your own OAuth client": create a Google web client with redirect URI `https://claude.ai/api/mcp/auth_callback` and have each friend type its client ID and secret into their connector dialog. The facts against it:
- The secret is shared with every user.
- Google's tokens carry the Google client ID as audience, not the MCP server URL, so the specification's audience rule cannot be met as written.
- Google returns a refresh token only when the request has `access_type=offline`, which is a Google-specific parameter. Claude asks for refresh by adding the `offline_access` scope, which Google's metadata does not list.
- Claude Code would need a second client, because its redirect is a loopback address.

**Google as the sign-in step behind another authorization server.** This is the pattern the SDK and the specification both describe. The authorization server is an ordinary Google OAuth client with one fixed redirect URI of its own.
1. Claude sends the user's browser to the authorization server's `/authorize`.
2. The authorization server redirects the browser to Google.
3. Google returns the user to the authorization server's callback with a code, which is exchanged for a Google ID token.
4. The authorization server validates the ID token: signature against Google's keys, `iss`, `aud` equal to its own Google client ID, and `exp` (https://developers.google.com/identity/openid-connect/openid-connect).
5. It checks the user against the invite list. This is the one place the invite list is enforced.
6. It shows a consent page naming the client, as the confused-deputy rule requires.
7. It redirects to Claude's callback with its own authorization code, and later issues its own access and refresh tokens bound to the MCP server URL.

Two Google details matter here:
- Google says to key users on the ID token's `sub` claim, which is unique and never reused, and not on `email`, which "may not be unique to this account and could change over time". An invite list written as email addresses therefore needs a rule for turning a first sign-in by email into a stored `sub`.
- A Google OAuth app left in "Testing" status issues refresh tokens that expire in 7 days, except when it requests only name, email and profile scopes (https://developers.google.com/identity/protocols/oauth2). In this pattern the app needs only those scopes, and does not need to keep Google tokens at all once the ID token is checked.

## Options for who issues the tokens

1. **Knowledge Pool is its own authorization server**, using the SDK's issuer mode, with Google as the sign-in step.
   - One process, one origin, no extra service or cost.
   - The app owns token storage, rotation, the consent page and the Google callback.
   - Claude connects by DCR. Getting CIMD would mean replacing the SDK's metadata and adding a client ID URL fetch.
   - Tokens must survive restarts, or every restart signs every connector out.
2. **A hosted identity service is the authorization server**, and Knowledge Pool runs the SDK's verify-only mode.
   - The service handles Google sign-in, client registration, consent and refresh.
   - The app writes a `TokenVerifier` and maps the token's subject to a user.
   - The invite list has to be enforced either in the service or by the app refusing unknown subjects.
   - Vendor documentation found by search (WorkOS AuthKit, Clerk, Stytch, Auth0) claims MCP support with DCR or CIMD; none of it was read or verified for this ticket.
3. **Google directly**, with a pre-registered client. Not viable for the reasons above.
4. **A fixed bearer token or API key.** On claude.ai this is a beta feature for some organizations and is one shared credential, so it cannot give each friend private decks. It works in Claude Code only.
5. **A sign-in proxy in front of the app** that redirects browsers to a login page. Not viable for the MCP endpoint unless the proxy itself speaks MCP authorization, because Claude acts only on a `401` with the bearer challenge. This follows from Anthropic's documented behaviour; no specific proxy was tested.

## Facts that bear on hosting

- The MCP endpoint, the protected resource metadata and the authorization server metadata all need public HTTPS URLs. The `resource` value must equal the URL users paste into Claude, and the issuer URL must be stable. Changing either means every user re-adds the connector.
- Claude gives discovery, registration and token endpoints 10 seconds. A host that scales to zero must wake and answer inside that, including the first unauthenticated request and the metadata fetches. The first tool call has 240 seconds.
- An IP allowlist for Anthropic's ranges can protect the MCP endpoint and the token, registration and metadata endpoints for claude.ai traffic, but not the authorization endpoint or the Google callback (the user's browser), and not Claude Code (the user's machine).
- The SDK's `Host` header check needs the public hostname listed (`KP_HTTP_ALLOWED_HOSTS` in `mcp_server.jac`).
- The simplest layout that satisfies discovery is one origin serving the MCP path, both `/.well-known/` documents and the OAuth endpoints. The web UI's browser sign-in is a separate mechanism (a session, not a bearer token), though it can reuse the same Google client and invite list.

## Not confirmed

- Whether Claude's client implements the 2026-07-28 specification changes. Anthropic's page lists versions up to 2025-11-25 only.
- The URL of the Client ID Metadata Document that the hosted Claude apps use. Only Claude Code's was found and fetched.
- Whether the callback will move to `https://claude.com/api/mcp/auth_callback`. A search result attributed this warning to an Anthropic help article (support.claude.com article 11503834), but that article returned 404 when fetched. The current documentation names only the `claude.ai` URL.
- Whether `153.61.208.0/20` is used for connector traffic. The connector page names only `160.79.104.0/21`; the IP reference lists both as outbound.
- Whether Google rejects or ignores the `resource` parameter Claude sends, and how long a Google access token lasts (Google's sample shows `expires_in` of 3920 seconds but gives no fixed figure).
- Whether Claude Code, when it registers by DCR, registers a redirect URI with the session's port or without one. The SDK's exact-match rule works only in the first case. This needs a test against a running server.
- That Claude Desktop reaches a remote connector from Anthropic's cloud rather than from the desktop machine. The documentation groups Desktop with the hosted apps for the callback URL and says the same infrastructure backs all surfaces, but does not state the network path for Desktop in so many words.
- Nothing here was run. No connector was added and no OAuth flow was exercised against the SDK.
