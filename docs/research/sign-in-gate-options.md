# What can put a Google sign-in and an invite list in front of the web app and the MCP endpoint

Research for issue #89, part of map #87. Researched on 2026-11-10.

## Short answer

Four kinds of option exist. They differ mainly in whether the claude.ai connector can get through them.

| Option | claude.ai connector works through it | App unreachable without it | Cost at about five users | How the invite list is edited |
| - | - | - | - | - |
| 1a. Cloudflare Access with Managed OAuth (an identity-aware proxy run by a CDN) | Designed to, but open reports from June to October 2026 say it fails on claude.ai while Claude Code works. Not confirmed working. | Yes, if the app is reached only through a Cloudflare Tunnel. | Free plan covers 50 users. Needs a domain on Cloudflare. | Email rule in an Access policy (dashboard, API or Terraform). |
| 1b. Railway's own platform | Railway has no identity-aware proxy that this research could find. | n/a | n/a | n/a |
| 1c. Google Cloud Identity-Aware Proxy | No. It has no sign-in flow a connector can follow. | Yes | Not on Railway. | Google Cloud access list. |
| 2a. oauth2-proxy as a second service | No, as of release 7.15.6. It works for the browser only. | Yes for the web app, over Railway private networking. The MCP path would have to bypass it. | One more small Railway service. | A file of email addresses, one per line. |
| 2b. Pomerium as a second service | Its documentation says yes and names Claude. Not tested here. | Yes, over private networking. | One more Railway service; other needs not confirmed. | A policy in Pomerium's configuration. |
| 3. Hosted auth service as the authorization server (WorkOS AuthKit checked most closely) | Yes by design: it offers both ways claude.ai registers itself. | No. The app is on the internet and checks every token itself. | WorkOS: free up to 1 million monthly users. | Invitations in the service's dashboard or API, with public sign-up turned off. |
| 4. Sign-in inside the app | Yes, if the app implements an authorization server. The MCP library already in the repo supplies the endpoints; the app supplies the Google step, the invite check and token storage. | No. The app is the public endpoint. | Nothing beyond hosting. | Whatever the app stores: a file, an environment variable or a graph node. |

Three facts narrow the choice:

1. **claude.ai cannot pass a cookie-based sign-in wall.** It needs the MCP endpoint to answer `401` and point to an OAuth authorization server that supports either Dynamic Client Registration or Client ID Metadata Documents. A classic sign-in proxy (oauth2-proxy, Google Cloud IAP) does neither, so it can protect the web app but not the connector.
2. **Google cannot be that authorization server directly.** Its metadata lists no registration endpoint and no Client ID Metadata Document support. Something must sit between claude.ai and Google and issue its own tokens: a proxy (1a, 2b), a hosted service (3) or the app (4).
3. **Only the proxy options (1a, 2a for the web app, 2b) keep the app off the internet.** With options 3 and 4 the identity check runs inside the app process, as middleware ahead of the tools.

The facts leave more than one viable option, so this document makes no recommendation.

## Terms

- **MCP endpoint**: the URL where the app accepts Model Context Protocol requests. A claude.ai **connector** is a saved link from a Claude account to that URL; the requests come from Anthropic's servers, not from the user's browser.
- **Authorization server**: the service that shows the sign-in page and issues access tokens. The MCP endpoint is the **resource server**: it accepts requests that carry a token.
- **Protected resource metadata** (RFC 9728): a small JSON document, served by the MCP endpoint, that names its authorization server.
- **Dynamic Client Registration** (DCR, RFC 7591): an endpoint on the authorization server where a client such as Claude registers itself and gets a client ID, with no human involved.
- **Client ID Metadata Document** (CIMD): the newer alternative. The client's ID is a URL to a JSON document describing the client, and the authorization server fetches it.
- **Identity-aware proxy**: a reverse proxy that checks who the caller is before it forwards a request to the app.
- **Private networking**: on Railway, services in one project reach each other at `SERVICE_NAME.railway.internal`; a service with no public domain is reached only that way.

## What claude.ai needs from whatever sits in front

Source for this section unless stated: Anthropic, "Authentication for connectors", https://claude.com/docs/connectors/building/authentication.md

- A remote MCP server can let Claude in by OAuth 2.0 (each user signs in), by a static credential in a request header, or with no authentication.
- The static header is in beta "for a limited set of organizations", is entered by an organization Owner, and is shared by everyone, so it cannot tell users apart. It is not a route to per-user decks.
- For OAuth, the MCP endpoint must answer an unauthenticated request with `401`, ideally with a `WWW-Authenticate: Bearer resource_metadata="..."` header. If the header is missing, Claude probes `/.well-known/oauth-protected-resource/<mcp-path>` and then `/.well-known/oauth-protected-resource` on the MCP server's origin.
- The metadata's `resource` field must equal the MCP URL exactly as typed into Claude. Claude uses only the first entry in `authorization_servers`. The authorization server may be on a different host.
- Claude identifies itself in one of three ways: CIMD (used only when the authorization server metadata advertises `"client_id_metadata_document_supported": true` and lists `"none"` in `token_endpoint_auth_methods_supported`), otherwise DCR, or a client ID and optional secret that the person adding the connector types in ("Use your own OAuth client").
- The redirect URI for claude.ai on the web, Desktop, mobile and Cowork is `https://claude.ai/api/mcp/auth_callback`. Claude Code uses a loopback redirect, `http://localhost:<any port>/callback` or `http://127.0.0.1:<any port>/callback`, and its own CIMD.
- Claude always sends PKCE with `S256`. The authorization server must support it.
- Claude waits 10 seconds for discovery, registration and token endpoints, and 30 seconds for a refresh. A host that scales to zero must wake inside that window.
- Claude's requests come from `160.79.104.0/21`. This covers discovery requests to the authorization server too.
- Custom connectors by URL are available on Free, Pro, Max, Ultra, Team and Enterprise plans; the Free plan allows one. On Team and Enterprise an Owner adds the connector and each member then connects with their own account. Authentication settings cannot be edited after a connector is added; it must be removed and added again. Source: https://claude.com/docs/connectors/custom/add-unlisted.md
- The MCP specification (2025-11-25) says the MCP server must validate that a token was issued for it, and must not accept other tokens. Source: https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization

Google as the authorization server: `https://accounts.google.com/.well-known/openid-configuration`, fetched on 2026-11-10, has no `registration_endpoint` and no `client_id_metadata_document_supported`, and lists only `client_secret_post` and `client_secret_basic` as token endpoint methods. So neither DCR nor CIMD can work against Google directly.

## Where the repo starts from

- `mcp_server.jac` runs one process with two listeners: the Jac web app (UI and REST) on `KP_PORT`, default 8000, and MCP over streamable HTTP on `KP_HTTP_PORT`, default 8020, when `KP_TRANSPORT=http`. Neither has authentication.
- The MCP listener rejects any `Host` or `Origin` header not listed in `KP_HTTP_ALLOWED_HOSTS`. Any proxy or public hostname in front of it must be added there.
- `pyproject.toml` pins `mcp==2.3.0`, `jaclang==0.16.7` and `jac-client==0.3.25`. The `jac-scale` plugin is not a dependency.
- Two ports matter for every proxy option: either the proxy routes two paths or hostnames to two ports, or the app is changed to serve both on one. Map #87 already lists this as not yet specified.

## Option 1: an identity-aware proxy run by the platform or a CDN

### 1a. Cloudflare Access with Managed OAuth

How it works:

- Cloudflare Access is an identity-aware proxy for hostnames on Cloudflare. A browser without a session is redirected to a sign-in page. Google is one of the identity providers it can use (not re-checked in this research).
- Managed OAuth is a per-application switch that makes Access an OAuth authorization server for non-browser clients. With it on, Access answers such clients with `401` and a `WWW-Authenticate` header instead of a redirect, serves discovery metadata, accepts DCR, and issues an opaque access token. It then passes the user's identity to the app as a signed JWT in the `Cf-Access-Jwt-Assertion` header. "Access enforces the same policies as a browser login." Source: https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/managed-oauth/
- DCR accepts only redirect URIs on an allow list (`dynamic_client_registration.allowed_uris`), plus optional switches for any `localhost` and any `127.0.0.1` client. `https://claude.ai/api/mcp/auth_callback` would have to be listed, and the loopback switches turned on for Claude Code. Same source.
- The documentation does not mention CIMD, so Claude would use DCR.
- Access tokens default to 15 minutes. On each refresh "Access policies are re-evaluated", so removing someone from the list takes effect within one token lifetime. Same source.
- The feature entered open beta on 2026-03-20. Sources: https://developers.cloudflare.com/changelog/2026-03-20-managed-oauth and https://blog.cloudflare.com/managed-oauth-for-access (published 2026-04-14). Whether it has since left beta was not confirmed.
- The app should still validate the `Cf-Access-Jwt-Assertion` JWT: signature against `https://<team>.cloudflareaccess.com/cdn-cgi/access/certs`, `aud` equal to the application's audience tag, `iss` equal to the team domain. The user's address is in the `email` claim. Source: https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/authorization-cookie/validating-json/ The Managed OAuth page says "Only enable Managed OAuth for MCP servers that validate the Access JWT sent by Cloudflare."

Does the claude.ai connector work through it: **not confirmed, and there is evidence against.** Reports in Anthropic's public tracker for connector problems:

- https://github.com/anthropics/claude-ai-mcp/issues/410 (June 2026, closed): claude.ai fails at Connect against Access Managed OAuth while Claude Code connects to the same URL. Four separate people reproduced it. One traced it to Access requiring the `resource` parameter on the authorization request. An Anthropic collaborator suggested Cloudflare bot challenges as the cause; one reporter showed that was not so in their case.
- https://github.com/anthropics/claude-ai-mcp/issues/980 (opened 2026-09-03, open, last comment 2026-09-09): sign-in and consent succeed on claude.ai, then no authenticated request reaches the origin. Claude Code completes the same flow.
- https://github.com/anthropics/claude-ai-mcp/issues/992 (closed 2026-10-12): an Anthropic collaborator read the traces and wrote that discovery, registration, the Access sign-in and the token exchange all completed and Claude sent the first MCP request with the new token; the reply was an empty `200` that never reached the reporter's origin. So the sign-in half can complete on claude.ai; that reporter's failure was in forwarding.

No report of a working claude.ai connector behind Access Managed OAuth was found. Cloudflare's pages name Claude Code, not claude.ai.

Does the app stay unreachable without it: yes, with a Cloudflare Tunnel. `cloudflared` runs next to the app and makes outbound connections only, so the app needs no public address. Source: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/ On Railway that would be `cloudflared` as a second service reaching the app over private networking, with no public domain on the app. Without a tunnel the app's own Railway domain stays reachable and the JWT check in the app is the only gate. Map #87 notes that Cloudflare has no standing and that an earlier session used a tunnel by chance.

Cost at about five users: the Zero Trust Free plan is $0 for up to 50 users and includes Access; the paid tier is $7 per user per month. Source: https://www.cloudflare.com/plans/sase-zero-trust/ (read through search results, not fetched directly). A domain managed by Cloudflare is required for the public hostname; its yearly fee was not priced. Railway cost is the app plus a small `cloudflared` service.

How the invite list is edited: an Allow policy on the Access application with the Emails selector, one address per entry, edited in the Zero Trust dashboard, the API or Terraform. Source: https://developers.cloudflare.com/cloudflare-one/access-controls/policies/ One list covers the browser and the connector.

### 1b. Railway

No identity-aware proxy or sign-in feature for deployed services was found in Railway's documentation. Railway's template catalogue offers community templates that add a proxy as another service: oauth2-proxy, basic-auth and bearer-token proxies, and self-hosted identity providers. Sources: https://railway.com/deploy/RfKH-J and https://docs.railway.com/guides/private-networking The absence of a native feature could not be confirmed from a page that says so.

### 1c. Google Cloud Identity-Aware Proxy

IAP protects apps on Google Cloud, such as Cloud Run. A program can get through it only with a Google-issued ID token or a service account token. Source: https://docs.cloud.google.com/iap/docs/authentication-howto That page describes no authorization server metadata, DCR or CIMD, so claude.ai has no flow to follow. It also means leaving Railway.

## Option 2: a self-run proxy as a second service

Common to both: on Railway the proxy gets the public domain and the app gets none. The proxy forwards to `http://<app>.railway.internal:<port>`. Private networking is scoped to one project environment. Source: https://docs.railway.com/guides/private-networking With Railway's serverless setting, a request over the private network wakes a sleeping service, and the first request may get a `502`. Source: https://docs.railway.com/reference/app-sleeping A second service is billed only for what it uses: $10 per GB of memory and $20 per vCPU per month, against the Hobby plan's $5 fee which includes $5 of usage. Source: https://docs.railway.com/reference/pricing/plans

### 2a. oauth2-proxy

- It is an open-source reverse proxy that sends browsers to a sign-in provider (Google is one) and sets a session cookie. Latest release 7.15.6, 2026-11-05.
- Invite list: `--authenticated-emails-file`, "authenticate against emails via file (one per line)". Source: https://oauth2-proxy.github.io/oauth2-proxy/configuration/overview Editing it means changing the file or the variable that produces it and restarting the proxy.
- It passes the signed-in address to the app in `X-Forwarded-Email` (`--pass-user-headers`). The app must trust that header only because nothing else can reach it.
- It is not an OAuth authorization server and serves no protected resource metadata. The request to support MCP is open: https://github.com/oauth2-proxy/oauth2-proxy/issues/3167 A pull request that adds RFC 9728 metadata, a `WWW-Authenticate` header and DCR proxying is open and unmerged (last updated 2026-10-05): https://github.com/oauth2-proxy/oauth2-proxy/pull/3488 Even merged, it proxies DCR to the provider's own registration endpoint, and Google has none.
- So the claude.ai connector does not work through oauth2-proxy with Google. The only way to combine them is to exempt the MCP path (`--skip-auth-route`), which leaves the MCP endpoint needing option 3 or 4 anyway, with the proxy passing its traffic through unchecked.
- It can accept a verified JWT bearer token from another issuer instead of a cookie (`--skip-jwt-bearer-tokens`, `--extra-jwt-issuers`). Whether that is enough for claude.ai, given the missing `401` metadata pointer, was not tested.

### 2b. Pomerium

- Pomerium is an open-source identity-aware proxy. A route marked `mcp: server: {}` makes it run the OAuth flow for MCP clients: the client "will go through Pomerium's OAuth flow, receive a bearer token, and use it for all subsequent requests", and the MCP server "does not need to handle authentication". The page names Claude, ChatGPT and VS Code as clients. Source: https://www.pomerium.com/docs/capabilities/mcp/protect-mcp-server
- The route carries a policy; the documented example allows an email domain. A list of named addresses is a standard Pomerium policy but was not seen on the pages read.
- Not confirmed: whether it offers DCR, CIMD or both; whether the MCP feature is still marked experimental; whether it needs a database; what the app receives to identify the user; whether anyone has it working with claude.ai (as opposed to Claude Code).

## Option 3: a hosted auth service as the OAuth authorization server

How it works: the service shows the sign-in page (with Google as the sign-in method), handles client registration, and issues tokens. The app becomes a resource server: it serves protected resource metadata, answers `401` with the pointer, and verifies each token's signature, issuer and audience. Google's client secret lives at the service, not in the app.

The installed MCP library already has the resource-server half. `MCPServer` takes an `auth=AuthSettings(issuer_url=..., resource_server_url=...)` and a `token_verifier`; with those it serves the metadata route, requires a bearer token and returns the `401` with `resource_metadata`. The app writes only the verifier. Source: `.venv/lib/python3.14/site-packages/mcp/server/mcpserver/server.py` lines 1189 to 1280, and `mcp/server/auth/settings.py`.

WorkOS AuthKit (checked most closely):

- It is the authorization server for an MCP server and supports both CIMD and DCR; each is a switch in the dashboard, and CIMD "is off by default". The MCP server URL is registered as a resource indicator so tokens carry it as `aud`. The app verifies JWTs against AuthKit's key set. Source: https://workos.com/docs/authkit/mcp
- Invite list: "When signup is disabled, users cannot register for a new account"; a valid invitation reopens registration for that person, "a closed-registration invitation-only system". Invitations are created in the dashboard or by API. Source: https://workos.com/docs/authkit/invitations How an existing user is removed was not checked.
- Cost: "First 1 million monthly active users free", social login included. A custom sign-in domain is $99 a month and optional. Source: https://workos.com/pricing

Others, less fully checked:

- Stytch Connected Apps: acts as the authorization server with DCR. CIMD, pricing and invite-only mode were not confirmed. Source: https://stytch.com/docs/guides/connected-apps/mcp-servers
- Clerk has MCP server guides for Next.js and Express only on the page read; nothing for Python was seen. Source: https://clerk.com/docs/guides/development/mcp/build-mcp-server
- Auth0 and Descope were not checked.

Does the claude.ai connector work: by design yes, since both of Claude's registration methods are offered. Not tested here.

Does the app stay unreachable: no. The app has a public address and rejects requests without a valid token. The check is library middleware inside the app process. The web UI is a separate job: the same service can sign browsers in, but the Jac web app then has to check that session on every REST call.

## Option 4: sign-in handled inside the app

How it works for MCP: the app is its own authorization server. Claude registers with the app, the app sends the browser to Google, Google returns the user's email address, the app checks it against the invite list and issues its own token.

- The installed MCP library has the endpoints. Passing an `auth_server_provider` to `MCPServer` adds `/authorize`, `/token`, `/register` (DCR) and optional `/revoke`, plus the metadata. The app must implement the `OAuthAuthorizationServerProvider` protocol: store registered clients, authorization codes, access tokens and refresh tokens, and write `authorize()` to redirect to Google and a callback route to finish. Source: `mcp/server/auth/provider.py`, `mcp/server/auth/routes.py`.
- That built-in authorization server advertises DCR and `S256` but not CIMD: `build_metadata` sets `token_endpoint_auth_methods_supported` to `client_secret_post` and `client_secret_basic` and never sets `client_id_metadata_document_supported`. So Claude would use DCR, which adds a registered client per fresh connection. Source: `mcp/server/auth/routes.py` lines 151 to 200.
- FastMCP, a separate package from the `mcp` SDK this repo uses, ships this as a ready component: an OAuth Proxy with a `GoogleProvider` that presents DCR and CIMD to MCP clients, uses one fixed Google OAuth client upstream, issues its own JWTs and shows a consent page. Its docs list `https://claude.ai/api/mcp/auth_callback` as a supported client callback. They do not describe restricting by email, and production use needs a signing key and a storage backend. Source: https://gofastmcp.com/servers/auth/oauth-proxy Whether it can be combined with this repo's `MCPServer` and MCP Apps code was not checked.

How it works for the web UI: Jac's guides describe Google sign-in through the `jac-scale` plugin: `[plugins.scale.sso.google]` with a client ID and secret in `jac.toml`, routes `/sso/google/login` and `/sso/google/register`, and `jacSsoLogin("google")` on the client; signed-in users each get their own graph root. Source: `uv run jac guide jac-sv-auth` and `jac-cl-auth`. `jac-scale` is not installed in this repo, and the guides show no hook for refusing an address that is not on a list.

Does the claude.ai connector work: yes in principle, since the app can meet every requirement in "What claude.ai needs" above. It is the most code to write and to get right.

Does the app stay unreachable: no. The app is the public endpoint, including its sign-in and registration routes.

Cost: nothing beyond hosting. A Google OAuth client is free.

Invite list: app data. An environment variable needs a redeploy to change; a file on the volume or a node in the graph can be edited in place.

## Combinations the facts allow

- A proxy for the browser only (2a) plus option 3 or 4 for MCP. This hides the web app but not the MCP endpoint, and keeps two invite lists unless the proxy's list is generated from the same source.
- Option 3 for both surfaces: one hosted service signs in browsers and issues MCP tokens, with one invite list. Nothing is hidden at the network level.
- Option 1a or 2b for both surfaces: one list, app hidden, but claude.ai support is unproven (1a has reports against it).

## Not confirmed

- That any claude.ai connector works today behind Cloudflare Access Managed OAuth. The open reports say otherwise; a short live test would settle it.
- Whether Managed OAuth is still in beta, and the Zero Trust Free plan's terms, which were read through search results because the pricing page did not load.
- Pomerium's MCP details: registration methods, status, storage, identity passed to the app, and claude.ai compatibility.
- That Railway has no native sign-in feature. None was found.
- Whether a service on Railway with no public domain is strictly unreachable from the internet. Railway's pages say private traffic has "No Public Exposure" but do not state it in those words.
- Whether a cold start on Railway's serverless setting fits inside Claude's 10-second limit, and whether Claude retries after the `502` a waking service may return.
- Stytch, Clerk, Auth0 and Descope pricing and invite-only modes. How WorkOS removes an existing user, and whether its Google sign-in needs the owner's own Google OAuth client in production.
- Whether Jac's `jac-scale` Google sign-in can enforce an invite list, and whether its tokens could be reused for MCP.
- Whether FastMCP's Google provider fits this repo's `mcp` 2.3.0 server.
- The "Use your own OAuth client" route with a Google client ID typed into Claude and Google named as the authorization server. Google's tokens are not issued for the MCP server, which the MCP specification forbids accepting, and every friend would need the client secret. It was not tested and is not listed as an option.
- Anthropic's support article 11503834 returned "404" to the fetch tool; the facts here come from the `claude.com/docs/connectors` pages instead.
