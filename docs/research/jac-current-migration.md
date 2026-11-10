# What moving from the pinned Jac to current Jac would take and change

Research for issue #99, part of map #87. Written 2026-11-10. It builds on `jac-deployment-and-storage` (#91) and `jac-users-and-roots` (#90) and does not repeat them.

"Pinned Jac" is `jaclang==0.16.7` with `jac-client==0.3.25` from PyPI (`pyproject.toml`). "Current Jac" is the self-contained `jac` binary, version 0.39.2, released 2026-11-09 (https://github.com/jaseci-labs/jaseci/releases/tag/v0.39.2).

Most of this file is from a trial, not from reading. The binary was downloaded into a scratch folder, with its home and cache folders redirected there. The repo at commit `f5fed6e` was copied beside it and migrated until it type-checked, its tests ran and its servers started. A second small app was used to re-test the cross-user leaks from #90 over real HTTP. Nothing in the repo folder or its `.venv` was changed. Each fact below says whether it was **tested** in that trial or **read** from the docs or source that ship inside the binary (`jac guide <name>`, and the runtime source it unpacks under `~/.cache/jac/rt/<hash>/site/jaclang/`).

## Short answer

- **The code port is small.** About 160 changed lines across 30 files (15 of them renames) took the copy from the pinned Jac to: `jac check` clean on every module, 65 of 65 Jac tests passing, 221 of 232 pytest tests passing, the web app serving its page and REST endpoints, and the MCP server answering tool calls over HTTP.
- **The work that remains is around the code, not in it.** The 11 failing tests all start processes through `uv`, `jac start`, `jac script` or `scripts/dev.sh`, which no longer exist or no longer apply. The MCP server can no longer start the web app on a background thread. The dev scripts, the CI workflow, the lock files, the README, `AGENTS.md` and the run skill all assume `uv` and the old commands. The web UI was built but not looked at in a browser.
- **Size estimate: 2 to 4 working days** for one developer working with an agent to reach the same single-user behaviour as today, with the suite green. The basis is in "Size estimate" below. Multi-user work is extra and is the same work on either version.
- **Every cross-user leak found in #90 is closed on 0.39.2.** Tested with two signed-in users over HTTP and again in process. Read and write grants behave as documented.
- **Current Jac changes the hosting picture in four ways.** Google sign-in is built in and public registration can be switched off. Plain walkers and functions are no longer endpoints. The graph is in Postgres, so the single-writer rule and the writer lock go away, and two processes shared one graph in the trial. The server is a new multi-worker HTTP engine with a published container base image.
- **It does not change the connector finding from #88.** Current Jac has no OAuth authorization server, so a claude.ai connector still needs sign-in endpoints from the app or a hosted identity service.

## Terms

- **Binary**: one downloaded executable, `jac`, that contains the compiler, its own Python 3.14, the server and the package tools. It replaces `uv`, the `.venv` and the PyPI packages.
- **Embedded Postgres**: a Postgres server the binary downloads and runs by itself on the local machine, used when no external database is configured.
- **`:pub`, `:protect`, `:priv`**: access tags on a walker or function. In current Jac they decide whether it is an HTTP endpoint at all.
- **Root, guest root, grant, walker**: as defined in `jac-users-and-roots.md`.
- **SSO**: single sign-on, here "Sign in with Google" handled by the Jac server.
- **JWT**: a signed token the server issues at sign-in and checks on each request.
- **Worker**: one server process. Current Jac starts several by default.

## Part 1: what the move takes

### Installing current Jac

- **Tested.** The Linux x86_64 binary is 154 MB and its SHA-256 matched the published `.sha256` file. On first run it unpacks a 679 MB runtime into `~/.cache/jac/rt/<hash>/` in about 3 seconds.
- **Tested.** On first use of the graph it downloaded an embedded Postgres 18.6 (14 MB download) into `~/.cache/jac/pg/dist/`. `jac db fetch` does this ahead of time.
- **Read.** The official install is `curl ... scripts/install.sh | bash` (https://github.com/jaseci-labs/jaseci/blob/main/README.md). Binaries exist for Linux x86_64 and aarch64 and macOS aarch64. Windows needs WSL.
- **Tested.** `HOME`, `XDG_CACHE_HOME` and `JAC_CACHE_HOME` move every cache, so the binary can be tried without touching a machine's real home folder.

### Config changes in `jac.toml`

Each of these stopped every `jac` command, including `jac guide`, until it was fixed. All tested.

| Old | New | How it was fixed |
|---|---|---|
| `entry-point = "main.jac"` | `entry-point = "main"` (a module name) | by hand |
| `[dev-dependencies] watchdog = ...` | `[dev-dependencies.pypi]` | `jac fix dependencies` |
| `[serve] base_route_app = "app"` | removed; the app is served at `/` | by hand |
| `kind = "fullstack"` | `kind = "web-app"` | by hand |
| `[plugins.client]` | removed | by hand |
| Python packages in `pyproject.toml` | `[dependencies.pypi]` in `jac.toml` (`mcp = "==2.3.0"`) | by hand |

`jac install --dev` then created `.jac/venv`, installed the Python and npm packages and wrote `jac.lock` in 33 seconds. `uv.lock` and `pyproject.toml` have no role afterwards.

### Language and API changes that touched this code

All tested: each row is an error the trial hit and fixed.

| Change | Where it hit | Caught by `jac check`? |
|---|---|---|
| `.sv.jac` and `.cl.jac` suffixes, `cl { }` blocks and `sv import` are removed; placement is inferred | 15 files renamed, `main.jac`, 5 client files | yes |
| Lambdas have one form, `lambda (e: T) { ... }` | 22 lambdas in 6 files | yes |
| `entry`, `exit` and `default` are keywords: no variable named `entry`, no bare `exit(1)`, `default=` needs a backtick | `deck_io.jac`, `seed.jac`, `shared_graph.jac`, `mcp_server.jac` | yes |
| Bare `dict` and `list` need type arguments | about 26 places, mostly `mcp_server.jac` | yes |
| Browser globals (`Blob`, `URL`) need a typed handle; two inline `# jac:ignore` comments in an `impl` file were not honoured | `export_panel.impl.jac` | yes |
| `jaclang.runtimelib.context` is now `jaclang.runtime.context`; `jaclang.jac0core.constant` is now `jaclang.runtime.constants`; `jaclang.runtimelib.testing` is now `jaclang.testing.testing` | `shared_graph.jac`, 7 pytest files | yes for Jac, no for Python |
| `UserManager.create_user` is gone; `ensure_internal_user` creates the guest user | `shared_graph.jac` | yes |
| `a ++> b` returns the new node, not a list, so `(a ++> b)[0]` fails | `cards.jac` | **no**: failed at run time in 8 tests |
| `obj` and `node` instances are no longer Python dataclasses, so `dataclasses.asdict` fails | `mcp_server.jac` `plain`, which shapes every MCP tool result | **no**: failed at run time in 2 tests |

Other points from the trial:

- `jac fix placement` renamed 10 of the 15 files and rewrote `main.jac`, but skipped the 5 client files with lambdas ("stripped source does not parse; migrate manually") and added a spurious second app, `[apps.walker_errors]`, which had to be deleted.
- `jac fix access` was not needed. It offered to mark `DeckAction`, `EditDeck`, `GetFormatRules` and `check_catalogue` as `:protect`. Left plain, they stop being endpoints, which suits them: on the pinned Jac they were token-protected endpoints nobody called over HTTP.
- `Jac.get_user_manager`, `Jac.get_context`, `Jac.push_request_context`, `Jac.spawn`, `Jac.commit`, `Jac.get_api_server_class` and `ExecutionContext.set_user_root` all still exist. `shared_graph.jac` `run_walker` worked after only the import renames.
- The type checker now runs on every compile. A module with a type error fails to import in tests.

### The server can no longer be started on a thread

**Tested.** `mcp_server.jac` `start_web` builds the server class and calls `start` on a background thread. On 0.39.2 that thread dies with `ValueError: signal only works in main thread of the main interpreter`, raised where the new server installs its signal handlers (`jaclang/server/serving/impl/supervisor.impl.jac`). The MCP half of the same process started normally.

**Tested.** The two halves ran as two processes instead: `jac run --no-dev` for the web app and `KP_WEB=0 KP_TRANSPORT=http jac run mcp_server.jac` for MCP. A deck created through an MCP tool appeared in the web app's `ListDecks` at once, and a deck created through REST appeared in the MCP `deck_list`. On the pinned Jac this layout is the one that overwrites decks.

How the two run on a host (two processes behind one address, or one process arranged differently) is a design choice the trial did not make.

### Storage changes that affect development and tests

- **Read.** "The store is Postgres, always." Locally the binary runs one embedded Postgres cluster for the whole machine under `~/.cache/jac/pg/main`, with one database per project "keyed to the project's absolute path". (`jac guide reference/persistence`)
- **Tested.** `JAC_DATA_PATH` no longer chooses where the graph lives. The server in the copy used the database keyed to the copy's path whatever `JAC_DATA_PATH` said. The seed tests, which set `JAC_DATA_PATH` to a temporary folder and run `jac run seed.jac`, wrote their decks into the copy's own database. `scripts/dev.sh`, `shared_graph.jac` `graph_dir` and those tests rely on the old behaviour.
- **Tested.** `JacTestClient.from_file(..., base_path=tmp)` still isolates: each `base_path` got its own database. One pytest run left 115 databases of about 8 MB each (969 MB). **Read:** they are dropped once their folder has been gone for 24 hours, or by `jac db prune -y`.
- **Tested.** Each git worktree has a different path, so each gets its own database without any script.
- **Read.** "Existing local SQLite data does not migrate automatically." (`jac guide community/breaking-changes`, Postgres entry.) Saved decks would be carried over through the app's own export and import.
- **Tested.** The embedded Postgres keeps running after the server stops, listening on a Unix socket only. `jac db stop` stops it.

### Commands, scripts, CI and docs

All tested unless marked.

| Today | Current Jac |
|---|---|
| `uv sync --locked` | `jac install --dev` (**read:** `jac install --frozen` for CI) |
| `uv run jac script <name>` | `jac x <name>`; `jac script` prints "was removed" |
| `jac start main.jac` | `jac run`; `jac start` prints "was removed" |
| `uv run pytest tests` | `jac x pytest tests` (ran the suite under the binary's Python) |
| `jac check *.jac` | unchanged |
| `jac test` | unchanged; runs tests in parallel workers |
| `jac browse` | still present |

- 50 lines in `scripts/`, `tests/`, `README.md`, `AGENTS.md`, `.claude/` and `.github/workflows/test.yml` mention `uv run`, `jac start`, `jac script` or the scripts that wrap them.
- The CI workflow installs `uv` and runs `uv sync --locked` then `uv run jac script check`. It would instead download the binary (a checksum file is published per release) and run `jac install`.
- A bare `jac run` in the copy started a development server: Vite on all network interfaces on the chosen port, and the API on the next port. `jac run --no-dev --host 127.0.0.1` gave one server on one port.
- In the small test project (`kind = "service"`), `jac run some_script.jac` did not run the script. It served the project on `0.0.0.0`, moved to port 8001 because 8000 was taken, and started one worker per CPU core. `jac run --no-serve some_script.jac` ran the script. Scripts such as `seed.jac` need checking for this.

### Test results in the copy

| Suite | Result | Time |
|---|---|---|
| `jac check *.jac` | 23 modules pass | 3 s |
| `jac test` | 65 passed | 2 s warm, 25 s first compile |
| `jac x pytest tests` (UI smoke test deselected) | 221 passed, 11 failed | 104 s |

The 11 failures:

- 5 in `test_dev_script.py` and 1 in `test_catalog_schema.py`: `scripts/dev.sh` calls `uv`, and the test calls `jac start`.
- 1 in `test_mcp.py`: `scripts/mcp_smoke.py` launches the server through `uv`.
- 3 in `test_seed.py`: the `JAC_DATA_PATH` change above.
- 1 in `test_legality.py`: REST responses carry a new `_jac_type_id` key beside `_jac_type`, `_jac_id` and `_jac_archetype`, and the test lists the keys it expects.

None is a failure of deck logic. `tests/test_ui_smoke.py` was not run.

### Size estimate

**2 to 4 working days** to reach today's single-user behaviour on current Jac with the suite green. Basis:

- Done in the trial, in one sitting: all config, language and import changes, the two run-time fixes, Jac tests green, the REST and MCP tests that run in process green. This part is about 160 changed lines and would be redone cleanly in under half a day.
- Not done, and sized by what the trial showed is involved:
  - Decide and build how the web app and MCP server start now that the thread is not allowed, and remove the writer lock and port check that guarded the single-writer rule (`mcp_server.jac`, `shared_graph.jac`).
  - Rewrite `scripts/dev.sh`, `scripts/jac_test.sh` and `scripts/mcp_smoke.py`, and the 10 process-level tests, for the new commands and for a graph that no longer follows `JAC_DATA_PATH`.
  - Replace `pyproject.toml` and `uv.lock` with `jac.toml` and `jac.lock`, and rewrite the CI workflow.
  - Run the UI smoke test and look at every view in a browser, including the MCP Apps views.
  - Update `README.md`, `AGENTS.md`, `CODING_STANDARDS.md` if it names old syntax, and the `run-knowledge-pool` skill.
  - Carry existing decks over by export and import.
- The spread from 2 to 4 days is the UI and the stdio MCP path, neither of which was exercised. Two changes got past the type checker and showed only when code ran, so untested paths may hold more.

One risk sits outside the estimate. Current Jac released five versions in 15 days (0.38.2 on 2026-10-25 to 0.39.2 on 2026-11-09), and its breaking-changes page has 34 entries, 17 of them still labelled "unreleased". `jac.toml` has a `[project] jac-version` pin (**read**, not tested), and each release is a separate download, so staying on one version is possible.

## Part 2: what current Jac changes for hosting

### The cross-user leaks from #90, re-tested

Method: a small app with a `Deck` node and the same walkers as the #90 appendix, served by `jac run` on a spare local port with one worker. Alice and Bob registered over HTTP. Alice created a deck. Nothing was granted. Every row was tested.

| Bob's action, with no grant | 0.16.7 (from #90) | 0.39.2 |
|---|---|---|
| `jobj(alice_deck_id)` | returned the deck | returns `None` |
| `jobj(alice_root_id)` | returned the root | returns `None` |
| `[alice_root -->][?:Deck]` and `[alice_root --> [?:Deck]]` | returned the deck | cannot be reached: the root is `None` |
| `allroots()` with a typed filter | listed every user's decks | empty |
| `POST /walker/ReadDeck/<alice_deck_id>` | ran and reported the name | 404 "Target node not found" |
| `POST /walker/ListMine/<alice_root_id>` | not tested in #90 | 404 |
| `POST /walker/Rename/<alice_deck_id>` | renamed the deck, and it stayed renamed | 404; the name is unchanged |
| Anonymous `POST /walker/PubList/<alice_root_id>` | listed Alice's decks | 404 |
| Anonymous call to a `:protect` walker | n/a | 401 |

The same checks held when walkers were run in process as each user (see "Running a walker as a user" below): Bob's `jobj` on Alice's new deck returned `None`.

Sharing, also tested:

| Step | Result |
|---|---|
| Alice runs `Jac.allow_root(deck, UUID(bob_root_id), AccessLevel.READ)` | Bob's `ReadDeck` on the deck returns its name; his access level reads as `READ` |
| Bob lists the deck's child nodes | empty: the grant covers the one node only |
| Bob renames the deck with only `READ` | HTTP 200, and the walker reports the old name; Alice still sees the old name |
| Bob attaches a child node with only `READ` | HTTP 200; Alice sees no new child |
| Bob copies the deck into his own root | works; the copy is his |
| Alice runs `Jac.disallow_root` | Bob's `ReadDeck` returns 404 again, and a copy attempt finds nothing |

Two things for the design to note:

- A refused write returns HTTP 200 with no error. The app cannot treat 200 as "the change was made".
- Grants are per node. Sharing a deck for viewing means granting the deck and every node a viewer must read under it, or copying.

`jac guide jac-sv-multi-user` still says "`jobj(id)` resolves any node by jid regardless of grants". The test contradicts that on 0.39.2. The guide's advice not to treat an id as a secret costs nothing to keep.

### Endpoint exposure

- **Read, and tested.** A plain `walker` or `def` is private: "never registered as an endpoint". `:protect` is the endpoint that needs a token and runs on the caller's root. `:pub` needs no token and runs on the guest root for anonymous callers. (`jac guide jac-sv-auth`.) In the trial an anonymous call to a `:protect` walker got 401.
- **Tested.** Every deck walker in this app is `:pub` today and stayed reachable without a token after the port. Per-user decks mean changing them to `:protect`.
- **Tested.** `GET /walkers` and `GET /functions` list endpoint names to anonymous callers, with no setting found to turn them off.
- **Tested.** `[serve] docs_enabled = false` and `graph_enabled = false` turned `/docs`, `/openapi.json` and `/graph` into 404s. They are on by default.
- **Tested.** The server creates an `admin` user on first start and writes its one-time password to the log. An admin portal is served at `/admin`. A normal user's token got 403 from `/admin/users`.
- **Tested.** Responses carry `Access-Control-Allow-Origin: *` by default. **Read:** `[serve] cors_origins` now sets the list, and `[]` turns cross-origin access off (`jac guide reference/plugins/jac-scale-http`). The deploy guide in the same binary still says there is "no knob"; the reference and the config schema are the newer text.
- **Read.** The `_authenticate` and `_before_request` walkers are still described in the HTTP reference, and a search of the 0.39.2 server source again found no code that calls them. There is no documented way for a proxy in front to hand the server a user identity in a header. `[serve.proxy] trusted` only makes the server believe `X-Forwarded-*` headers.

### Sign-in

- **Read.** Google, Apple and GitHub sign-in are built into the server. Configure `[scale.sso.google] client_id` and `client_secret` and `[scale.sso] host`. Routes: `GET /sso/google/login`, `/sso/google/callback`, plus `POST /sso/google/begin` and `/finish` for a flow the client drives with PKCE. (`jac guide reference/plugins/jac-scale-http`, "SSO".) **Tested:** with nothing configured, `/sso/google/login` answers 501 `SSO_NOT_CONFIGURED`.
- **Tested.** `[serve.auth.registration] enabled = false` makes `POST /user/register` answer 403 `REGISTRATION_CLOSED`. The pinned Jac had no such switch.
- **Read.** With registration closed, "SSO signs in existing accounts but creates none". The source agrees: `federated_identities` returns `REGISTRATION_CLOSED` before creating a user (`jaclang/scale/sso/impl/oauth_session.impl.jac`, lines 9-16).
- **Read.** A Google sign-in is matched to an existing account in this order: a Google account that has signed in before; otherwise an account holding the same email as a **verified** identity. If the account's email is not verified, sign-in fails with `SSO_EMAIL_IN_USE` (same file, `complete_identity`).
- **Read.** An account an admin creates through `POST /admin/users` gets its email stored unverified: the handler passes only `type` and `value`, and storage defaults `verified` to false for emails (`jaclang/scale/admin/impl/admin_portal.impl.jac` lines 763-800; `jaclang/server/identity/impl/identity_storage.impl.jac` line 54). So "close registration, have the admin add each invited email, let them sign in with Google" does not work from the admin API alone. The routes the source leaves open are: email verification through a configured mail sender; app code that calls `UserManager.set_identity_verified` or creates the user with a verified email; or app code that links the Google account id with `link_sso_account`. None was run.
- **Read.** `[serve.auth.email] allowed_domains` limits sign-up by email domain, which does not help a group of personal Gmail addresses.
- **Read.** Sessions are JWTs signed with HS256, valid 7 days, with a refresh endpoint and no revocation. A local server writes its own signing secret to `.jac/data/jwt_secret`; a deployment must set `[serve.auth] secret` or `JAC_SERVE_AUTH_SECRET`. Passwords are hashed with scrypt. Optional TOTP second factor exists.
- **Read.** Requests authenticate by `Authorization: Bearer`. An opt-in cookie, `[serve.auth] session_cookie = true`, carries the same token but is read for `GET` and `HEAD` only.
- **Read.** After a browser SSO sign-in the server can redirect to `client_auth_callback_url?token=<JWT>`, so the token still passes through a URL in that flow. Access logs redact `token` query values.
- **Read.** No OAuth authorization server: a search of the server and scale source for `.well-known`, `oauth-authorization-server`, `oauth-protected-resource` and `registration_endpoint` found nothing outside tests. API keys exist for webhooks only. The finding in #88 stands.
- **Read.** `UserManager` exposes `create_jwt_token(user_id)`, `validate_jwt_token(token)` and `get_jwt_claims(token)`, so app code that runs its own sign-in could issue or check Jac's tokens. Not run.

### Running a walker as a user from the MCP server

**Tested.** The method from #90 still works with one change: `get_root_id` now takes a user id, found with `um.find_user_by_identity(username_or_email)`. A script set each user's root on an `ExecutionContext`, spawned walkers, and got each user's own decks; Bob's attempt to reach Alice's deck by id returned nothing. So an MCP tool call that knows who the caller is can act as that user in process, and the access rules apply there too.

### Storage on a host

- **Read.** Set `JAC_DB_URL` (or `[scale.database] url`) to a `postgresql://` URL and the server uses that database instead of the embedded one. Users, API keys and the graph are all in it. (`jac guide jac-sv-deploy`, `jac guide reference/persistence`.)
- **Read.** Each request is one `SERIALIZABLE` transaction; a request that loses a race is replayed; this "holds identically for a single local process and a multi-pod deployment sharing one database".
- **Tested in a small way.** Two processes on one machine sharing the embedded database saw each other's writes at once. No concurrent-write test was run.
- **What follows for the map.** The facts from #91 and #92 that came from the single-writer SQLite file ("one volume, one instance", "a second instance exits at the graph lock", "deploys must not overlap") would not apply. The graph would be a Postgres database, which Railway offers as a service, and backup would be a Postgres dump. The catalogue is unaffected: it is still the app's own read-only SQLite file.
- **Read.** The embedded Postgres can run inside the app's container instead: it must not run as root, and `JAC_CACHE_HOME` is the folder to put on a volume. (`jac guide reference/persistence`, "The embedded engine in containers".) That keeps one service but brings back one volume and one instance.

### Workers, memory and start time

- **Read.** With no setting, the server starts one worker process per CPU core; `[serve.workers] count = "1"` or `jac run -w 1` sets one. Module globals exist once per worker. **Tested** by accident: the unconfigured test project started six worker processes on a six-core machine.
- **Tested**, on the development machine with warm caches, one worker:
  - Test service, restart: healthy in 1.5 seconds.
  - This app, `jac run --no-dev`, first start after a change: healthy in 6.2 seconds, of which 2.1 seconds was the client bundle build.
  - Memory at idle: web server 243 MB, MCP process 139 MB, embedded Postgres about 100 MB.
- The health endpoints are `/healthz`, `/healthz/live` and `/healthz/ready`. `/health` and `/ready`, named in the deploy guide, returned 404.
- **Read.** SIGTERM gives requests in flight 10 seconds to finish (`[serve.timeouts] drain`). **Tested:** stopped servers logged "drain: started".

### Container image

- **Read.** Upstream publishes `jaseci/jaclang:<version>`, built from `debian:trixie-slim`, with the binary, the unpacked runtime and the embedded Postgres already inside, and a default user with uid 1000. (https://github.com/jaseci-labs/jaseci/blob/main/docker/jaclang.Dockerfile)
- **Read.** `jac scale deploy` still targets Kubernetes only, and the docs still name no platform service. A Railway image would be written by hand on that base: copy the app, run `jac install`, build the catalogue, start with `jac run`.
- **Read.** `jac build` produces a `.jab` bundle that `jac run app.jab` serves. Not tried.

## Options the facts leave open

1. **Stay on 0.16.7.** No port. The leaks, open registration, password-only sign-in and single-writer SQLite from #90 and #91 all remain, and the app's own code has to cover each. PyPI will get no fixes.
2. **Move to current Jac first, then build multi-user on it.** Two to four days before any multi-user work. In return: Jac's access rules can be a real second layer, registration can be closed, Google sign-in for the browser exists, plain walkers stop being endpoints, and storage becomes Postgres. The connector's OAuth and the invite list are still the app's to build. The app takes on a toolchain that changes weekly.
3. **Move later.** Build on 0.16.7 with app-level ownership checks and port afterwards. The port's size would grow with the code written in between, and the ownership checks would be written against behaviour that current Jac changes.

## What could not be confirmed

- A real Google sign-in. No Google client was configured, so the SSO flow, the account-linking rule and the invite routes are from the docs and source only.
- Whether any of the invite routes (verified email by mail, `set_identity_verified`, `link_sso_account`) works as read.
- The web UI in a browser, the UI smoke test, and the MCP Apps views. The client bundle built and the page shell was served; nothing was rendered.
- MCP over stdio on current Jac. Only streamable HTTP was run.
- Whether the web app and MCP server can share one process and one port on current Jac.
- Behaviour with more than one worker, and under concurrent writes to one deck.
- Start time and memory in a clean container, and anything on Railway.
- `jac install --frozen`, the `jac-version` pin and `.jab` bundles.
- Carrying existing decks from SQLite to Postgres.
- Why two inline `# jac:ignore` comments in an `impl` file were not honoured.
- Why a bare `jac run` chose development mode in the copy.
- Whether upstream regards the leak fixes as guaranteed behaviour. The runtime ships tests under `jaclang/scale/tests/`, which were not read, and the issue tracker was not searched.
- External Postgres through `JAC_DB_URL`. Only the embedded server was used.

## Appendix: how to repeat the trial

Environment, so nothing lands in the real home folder:

```bash
export HOME=$SCRATCH/home XDG_CACHE_HOME=$SCRATCH/home/.cache
gh release download v0.39.2 -R jaseci-labs/jaseci -p 'jac-0.39.2-linux-x86_64*'
sha256sum jac-0.39.2-linux-x86_64   # compare with the .sha256 file
```

Port of a copy of the repo, in the order the errors appeared:

```bash
git archive HEAD | tar -x -C $SCRATCH/copy && cd $SCRATCH/copy
# jac.toml: entry-point = "main"; drop [serve] base_route_app and [plugins.client];
#           kind = "web-app"; add [dependencies.pypi] mcp = "==2.3.0"
jac fix dependencies
jac fix placement          # then rename the 5 skipped .cl.jac files, change
                           # `sv import` to `import`, delete [apps.walker_errors]
# lambdas -> lambda (x: T) { ... }; rename `entry` variables; exit(1) -> sys.exit(1);
# dict -> dict[str, any]; jaclang.runtimelib.* -> jaclang.runtime.* / jaclang.testing.testing;
# (a ++> b)[0] -> (a ++> b); replace dataclasses.asdict with a walk over vars()
jac install --dev
jac check *.jac && jac test && jac x pytest tests
jac run --no-dev --host 127.0.0.1 -p <port> -w 1
KP_WEB=0 KP_TRANSPORT=http KP_HTTP_PORT=<port2> jac run mcp_server.jac
jac db stop
```

Leak test app (`jac.toml` with `kind = "service"`, `entry-point = "main"`):

```jac
import from jaclang { JacRuntime as Jac }
import from uuid { UUID }

node Deck { has name: str; }

walker:pub PubList {
    can go with Root entry {
        report {"root": jid(here), "decks": [d.name for d in [here -->][?:Deck]]};
    }
}
walker:protect Create {
    has name: str;
    can go with Root entry {
        d = here ++> Deck(name=self.name);
        report {"id": jid(d), "root": jid(here)};
    }
}
walker:protect ListMine {
    can go with Root entry {
        report {"root": jid(here), "decks": [d.name for d in [here -->][?:Deck]]};
    }
}
walker:protect ReadDeck { can go with Deck entry { report here.name; } }
walker:protect Rename {
    has name: str;
    can go with Deck entry { here.name = self.name; report here.name; }
}
walker:protect Share {
    has target_root: str;
    can go with Deck entry {
        Jac.allow_root(here, UUID(self.target_root), AccessLevel.READ);  # jac:ignore[E1053]
        report "shared";
    }
}
```

A `Probe` walker run as Bob called `jobj` on Alice's root id and deck id, the typed and untyped traversals, `Jac.check_access_level` and `allroots()`. Requests were plain HTTP:

```bash
curl -X POST $B/user/register -H 'Content-Type: application/json' -d '{
  "identities": [{"type": "username", "value": "alice"}],
  "credential": {"type": "password", "password": "<8+ chars, not containing the name>"}}'
curl -X POST $B/walker/Create -H "Authorization: Bearer $ALICE" -H 'Content-Type: application/json' -d '{"name": "A1"}'
curl -X POST $B/walker/ReadDeck/$DECK -H "Authorization: Bearer $BOB" -H 'Content-Type: application/json' -d '{}'   # 404
curl -X POST $B/walker/Rename/$DECK   -H "Authorization: Bearer $BOB" -H 'Content-Type: application/json' -d '{"name": "HACKED"}'   # 404
curl -X POST $B/walker/PubList/$ALICE_ROOT -H 'Content-Type: application/json' -d '{}'   # 404
```
