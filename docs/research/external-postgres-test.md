# Current Jac storing its graph in an external Postgres

Test for issue #105, part of map #87. Run 2026-11-13. It settles the condition on "Decide: where it is hosted and where the graph is stored" (#96).

Everything below was **tested** unless marked **read**. Nothing in the repo or the real home folder changed.

## Short answer

- **It works. The fallback (embedded Postgres on a volume) is not needed.** With `JAC_DB_URL` set, Jac 0.39.2 stored users and decks in Railway's own Postgres image, on Postgres 18 and 17.
- **No embedded Postgres was fetched or started.** With `JAC_DB_URL` set from the first run, the cache folder never gained a `pg` folder and no Postgres process ran.
- **The two processes shared one database.** A deck made in the web app appeared in the MCP server at once and the other way round, and both read the same decks after a restart.
- **The two-user privacy test passed unchanged.** Every call returned the same status and the same data as on the embedded Postgres.
- **Jac's database client has no TLS.** It connects in plain text and ignores `sslmode` in the URL. Railway's image accepts that. A server that insists on TLS refuses it.
- **Two things need doing on the Postgres service**: it needs one setting raised (`max_pred_locks_per_transaction`), and the app needs a database user that may create tables.
- **One new problem, not caused by the external database**: when the web app and the MCP process write the same deck at the same moment, the MCP process's way of running a walker fails and then blocks every later write. A small change to `run_walker` fixed it in the test. See "Concurrent writes".

## How it was run

- The `jac` 0.39.2 binary (checksum matched), with `HOME`, `XDG_CACHE_HOME` and `JAC_CACHE_HOME` pointed at a fresh scratch folder.
- Postgres: `ghcr.io/railwayapp-templates/postgres-ssl`, tags `18` (18.6) and `17` (17.11), in Docker, published on a local port. This is the image Railway's Postgres template deploys (its README says so). Started the way Railway starts it: user `postgres`, database `railway`, `PGDATA` under `/var/lib/postgresql/data` (the image refuses to boot otherwise).
- The image's settings as shipped: `ssl = on`, `max_connections = 100`, and one access rule for outside connections, `host all all all scram-sha-256`. That rule takes TLS and plain connections alike.
- Two apps:
  - The small two-user app and its drivers from #103 (`shared-card-two-user-test/`), unchanged.
  - A fresh port of the real app at `baea001` to 0.39.2, following the recipe in `jac-current-migration.md`. The earlier trial copy no longer existed. The port is `external-postgres-test/port-to-0.39.2.patch` (28 files, 166 lines added, 145 removed). It type-checks, and `jac test` passed 56 tests with one test file left unported. It is a test rig, not the port.
- The real app ran as two processes, as in #101: `jac run --no-dev --host 127.0.0.1 -p <port> -w 1` for the web app and `KP_WEB=0 KP_TRANSPORT=http jac run mcp_server.jac` for MCP. Drivers: `two_process.py` and `concurrent_writes.py`.

Not tested: Railway itself, its private network, more than one Jac worker, WorkOS users.

## Results

### Does the server start without the embedded Postgres

Yes. On a fresh home with `JAC_DB_URL` set, the server started in a few seconds and the cache folder held only `jir`, `rt` and `toolchains`. A plain `jac test` without `JAC_DB_URL` did download and start the embedded Postgres, so the variable must be set for every Jac command the image or a deploy runs, not only for the server.

### Do users and decks land in that database

Yes. Jac created 11 tables in the `public` schema on first start: `anchors`, `graph_types`, `kv_state`, `quarantine`, `jac_docs`, `jac_outbox`, `jac_outbox_seen`, `identity_users`, `identity_lookups`, `identity_oauth_grants`, `sso_lookups`. Decks, cards and edges are rows in `anchors`; users are rows in `identity_users`. The real app with two decks took 8 MB.

Both processes kept working after the Postgres container was restarted under them. Neither needed a restart.

### Do the two processes share it

Yes.

| Step | Result |
|---|---|
| Web app creates "web deck" | MCP `deck_list` shows it |
| MCP `deck_create` "mcp deck" with 4 Lightning Bolt | web `ListDecks` shows both |
| Web `AddCard` 20 Mountain to the MCP deck | MCP `deck_get` shows Bolt 4, Mountain 20 |
| MCP `deck_edit` sets Mountain to 18 | web `GetDeck` shows 18 |
| Both processes restarted | both list both decks |

### Does the two-user privacy test still pass

Yes. The four drivers from #103 ran against Postgres 18, and the main one again against 17. With ids replaced by placeholders, the main driver's output matched the #103 run on the embedded Postgres line for line (2,905 lines), apart from the app listing more endpoints than it had at that run. On 17 every call label and status code matched. The in-process guest script (`inproc.jac`) also worked against the external database.

### What the database user needs

- **A database that already exists.** Jac does not create it: a URL naming a missing database fails with `database "nosuchdb" does not exist`.
- **The right to create tables in the `public` schema.** A user who owns the database, with no superuser, create-database or create-role rights, was enough for everything above. A user with connect rights only is refused at startup: the server exits with `permission denied for schema public` and never listens.
- **No extensions.** Only the built-in `plpgsql` was present afterwards.
- Railway's default user (`postgres`, a superuser) and default database (`railway`) therefore work as they come. A separate, weaker user is possible but not needed.

### SSL

- Jac's client (`jaclang/data/pgwire.jac`) opens a plain socket and has no TLS code (**read**, and confirmed by test: Postgres reported the connections as not encrypted).
- `?sslmode=require` and `?sslmode=disable` in the URL are both accepted and ignored. `postgres://` and `postgresql://` both work.
- With the image as shipped, nothing is needed in the URL.
- When the access rule was changed to TLS only (`hostssl`), Jac could not connect, with or without `sslmode=require`: `no pg_hba.conf entry ... no encryption`.
- So traffic between the app and Postgres is unencrypted. On Railway that traffic stays on the project's private network, which #96 already requires (no public address for Postgres). It is one more reason never to give the Postgres service a public address.

### Connections

- Idle: the web process holds 2 to 3 connections and the MCP process 1 to 2.
- Under load a process opens one connection per request in flight, with no cap: 40 simultaneous requests gave 41 connections. All 240 requests succeeded.
- Afterwards the process keeps up to 16 idle connections for 5 minutes (`JAC_DB_POOL_MAX`, `JAC_DB_POOL_IDLE_S`; **read**, and 18 were seen held).
- The image allows 100 connections. A handful of users will not come near it. A flood of requests could, which the front door's rate limit (#108) already has to prevent.

### A setting Jac asks for

At every start against the Railway image Jac logs a warning: `max_pred_locks_per_transaction` is 64 and should be 1024, or requests can fail under load with `out of shared memory`. Running `ALTER SYSTEM SET max_pred_locks_per_transaction = 1024` as `postgres` and restarting Postgres removed the warning. On Railway that is one SQL statement and one restart of the Postgres service, done once.

### Memory

After a restart and light use the web process used about 275 MB and the MCP process about 265 MB (resident), or about 220 MB and 210 MB counting shared pages once. Right after its first start the web process stood at 386 MB. #96 assumed about 380 MB for the two together, so the app may cost a dollar or so more a month than estimated there.

## Concurrent writes

This is the first test on the map to write from two processes at once. The behaviour comes from Jac's transactions on Postgres, so it applies to the embedded Postgres too.

- **As ported, one conflict jams the MCP process.** `shared_graph.jac` `run_walker` spawns the walker and commits. When the web app changed the same deck at the same moment, the commit raised a conflict, the transaction was left open, and from then on every MCP call failed and web writes to that deck waited until they timed out (60 s). Only restarting the MCP process cleared it. Sequential calls never showed this.
- **Jac's own server does not jam.** It rolls back and re-runs the walker (**read** in `jac guide reference/persistence`, and seen in the log).
- **The fix that worked in the test**: in `run_walker`, on any error call `ctx.mem.abort()`; if the error is a `WriteConflict` or `transient_db_error(e)` is true, run a fresh copy of the walker again, up to a few times. It is in the patch. With it:
  - 2 web writes against 10 MCP edits on one deck, six runs: every call succeeded, with 6 re-runs logged.
  - 25 web writes against 10 MCP edits on one deck: no jam; 1 MCP call in 10 and, in one run, 5 web calls in 25 still returned an error (409 or 500 from Jac's own server). That is far beyond what a few users will do.
- A walker that has side effects outside the graph would repeat them on a re-run. The deck walkers have none.

This matters for #101, where the front door runs every deck action in process for both Claude and the web page: that code path needs the roll-back and re-run, and a test for it.

## What this changes for the cards it blocked

- **#96**: the Postgres half is no longer conditional. Two services, as decided.
- **Backups (#107)**: the graph is an ordinary Postgres database of 11 tables in `public`, owned by one user, with no extensions. Standard Postgres dump and restore, and Railway's own backups, apply. The identity tables (`identity_users` and the three beside it) are in the same database and must travel with the graph.
- **Deploys and secrets (#109)**:
  - `JAC_DB_URL` is the one database setting. Railway's `DATABASE_URL` reference variable can be mapped to it as it is.
  - It must be set for every Jac command that runs in the image, or Jac downloads and starts its own Postgres.
  - One-time setup on the Postgres service: raise `max_pred_locks_per_transaction` to 1024 and restart it.
  - No `sslmode` and no certificate handling.

## Files

- `external-postgres-test/port-to-0.39.2.patch`: the scratch port, including the `run_walker` change.
- `external-postgres-test/two_process.py`, `concurrent_writes.py`: drivers for the two processes.
- `external-postgres-test/restart.sh`, `small_app.sh`: how the servers were started.
- The two-user app and drivers are in `shared-card-two-user-test/` on branch `research/shared-card-two-user-test`.
