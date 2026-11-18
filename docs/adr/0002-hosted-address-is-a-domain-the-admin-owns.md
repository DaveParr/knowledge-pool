# The hosted app's address is a domain the admin owns, not the one Railway generates

The hosted app answers at `https://knowledge-pool.engi.ai`, with the claude.ai connector at `/mcp` on the same host, although Railway offers a free generated address that needs no setup. The address can never change without cost: every user's connector entry holds it, and so do the redirect address and Resource Indicator at WorkOS, the app's token audience and its browser origin check. A generated `*.up.railway.app` name belongs to Railway, so leaving Railway would make every user re-add the connector, and Railway's docs do not say the name survives rebuilding the service. A name the admin owns survives any change of host.

## Considered Options

- **Railway's generated address.** Free, nothing to renew. Turned down for the reason above.
- **A separate `mcp.` hostname for the connector.** Turned down: one front door serves both the web UI and the connector, and a second name is a second address to keep fixed.
- **A proxy or CDN in front of Railway.** Turned down: Railway's docs warn that certificates may not issue for proxied names, and it puts a party in front of the front door that was never tested with claude.ai.

## Consequences

- The domain must not lapse. Someone else could register it and serve a fake app to connectors that still point at it. The admin owns `engi.ai` personally at Hostinger with auto-renew on.
- The session cookie is set for the exact host only, never for all of `engi.ai`, so other sites under the domain never receive it.
- Hostinger's DNS cannot point a bare root domain at Railway, so the app must stay on a subdomain while the DNS is there.

Decided in "Decide: the fixed address of the hosted app" (#106).
