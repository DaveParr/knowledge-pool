# The deck graph is in a separate Postgres service, reached in plain text over the private network only

The hosted app keeps its deck graph and its users in Railway's Postgres service, a second service beside the app, and connects to it without TLS. Current Jac's database client has no TLS: it opens a plain socket and silently ignores `sslmode` in `JAC_DB_URL`. Railway's Postgres image accepts plain connections, so this works, and the traffic never leaves the project's private network. The Postgres service therefore never gets a public address (no TCP proxy), and that rule is what keeps deck data and sign-in records off the internet in the clear.

## Considered Options

- **Jac's embedded Postgres inside the app container, on a volume.** No network hop at all. Turned down: a volume ties the app to one instance and brings a short outage on every deploy, and the external service was tested and works.
- **A TLS-only Postgres.** Turned down because it cannot work: with the server set to refuse plain connections, Jac could not connect, with or without `sslmode=require`.

## Consequences

- Never enable the TCP proxy on the Postgres service, even briefly to look at the data. The admin reaches the database through Railway's own tools.
- Moving Postgres to another provider, or anywhere reached over the internet, is not possible until Jac's client supports TLS.
- `JAC_DB_URL` must be set for every Jac command that runs in the image. Without it Jac downloads and starts its own Postgres.
- The Postgres service needs `max_pred_locks_per_transaction` raised to 1024 once; Jac warns at every start until it is.

Decided in "Decide: where it is hosted and where the graph is stored" (#96) and confirmed by "Test: current Jac storing its graph in an external Postgres" (#105).
