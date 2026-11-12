# Live test results (issue 102)

Run on 2026-11-12 against a WorkOS Staging environment, a throwaway server on Railway
(`server.py` here) and a real claude.ai account. Answers come from the admin's run of
`wizard.sh`, follow-up questions, and the server's log.

## What was confirmed

- **claude.ai connects.** A custom connector signed in through AuthKit with Google and called
  `whoami`. The server accepted the token: `iss` the AuthKit domain, `aud` the MCP URL
  (`https://<host>/mcp`), `sub` a WorkOS user id (`user_...`), lifetime 299 seconds.
- **Registered by CIMD.** Dynamic Client Registration was off at WorkOS throughout. The token's
  `client_id` was `https://claude.ai/oauth/mcp-oauth-client-metadata`.
- **An uninvited Google account is refused** at AuthKit's sign-in page ("This account does not
  exist"), with sign-up off.
- **An invitation cannot be accepted with a different address** (Gmail addresses, organization
  invitation): refused.
- **Removal ends the connector's access.** After the admin deactivated the user's organization
  membership and revoked their sessions, the connector stopped working at the next check about
  7 minutes later and claude.ai asked the user to sign in again. The server log shows no accepted
  token after the removal and one expired token refused. The two actions were done together, so
  the test does not show which of them is needed.
- **After the user is deleted**, a sign-in attempt gets "This account does not exist".

## What was not confirmed

- **Claude Code over HTTP, end to end.** AuthKit accepted Claude Code's own client identity
  (`https://claude.ai/oauth/claude-code-client-metadata`) and showed its sign-in page, but the
  only user had been deleted by then, so no token was issued and `whoami` was never called.
- The exact time between removal and loss of access (only "within about 7 minutes").
- Production behaviour with the admin's own Google OAuth client: Staging's default Google
  credentials were used.

## What the admin had to set

At WorkOS (dashboard paths as found):
- Authentication, OAuth providers: Google on. Staging's default credentials were enough.
- Authentication, Features (`/authentication/features`): sign-up off; other sign-in methods off.
- Connect, Configuration: "Client ID Metadata Document" on. It is off by default, and AuthKit's
  metadata only advertises CIMD once it is on.
- Connect, Configuration, Resource Indicators: the full MCP URL **including the path**
  (`https://<host>/mcp`), set as default. With only the bare origin registered, AuthKit answered
  `invalid_target` and claude.ai showed "Authorization with ... failed" with no further detail.
- Organizations: one organization; invitations sent from it.

At Google: nothing in Staging.

On the server: the AuthKit domain (issuer) and its own public MCP URL (audience). No secrets.

## Other observations

- AuthKit keeps its own browser session. Removing and re-adding the connector signs the same
  person in again without showing Google's account chooser.
- The address a person signs up to the WorkOS dashboard with can also be invited as a user of
  the environment; the two are separate.
- Railway ran the server from the Dockerfile and supplied `PORT` (8080). Railway CLI 3.3.1 could
  not complete its browser sign-in; 5.71.0 could.
