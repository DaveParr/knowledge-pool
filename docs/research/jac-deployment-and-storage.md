# Jac's recommended deployment architecture, graph storage and scale to zero

Research for issue #91 (part of map #87). Checked on 2026-11-10 against the versions this repo pins: `jaclang==0.16.7`, `jac-client==0.3.25`, `mcp==2.3.0` (`pyproject.toml`). Paths under `jaclang/` are in `.venv/lib/python3.14/site-packages/jaclang/`. Paths under `jac_scale/` are from the `jac-scale` 0.2.31 wheel on PyPI, which this repo does not install.

## Short answer

- Jac documents two ways to serve an app at the pinned version. Plain `jac start` is one process on one machine with the graph in SQLite files under `.jac/data/`. The `jac-scale` plugin adds MongoDB (graph) and Redis (cache), and its only automated deployment target is Kubernetes (`jac start --scale`). Jac documents no path for Railway, Fly, Render, Cloud Run, Docker Compose or any other platform service.
- The app as it stands (one process, SQLite graph) can stop and start again without losing decks, provided `.jac/data/` sits on a disk that outlives the process. Nothing about the graph lives only in memory after a request has finished. Jac has no scale-to-zero feature of its own outside Kubernetes; on a platform service, stopping and waking the process is the platform's job.
- More than one process can write the graph only with `jac-scale` on MongoDB (Redis is needed as well for the processes to see each other's writes promptly). On SQLite, every Jac source says one writer process only.
- Cold start time was not measured (the brief forbids starting the app) and Jac publishes no figure. The steps a cold start runs are listed below; the one large avoidable step is building the browser bundle, which is skipped when the bundle is already on disk.
- The pinned version is the last one published to PyPI (19 June 2026). Jac has since moved to a self-contained binary (0.39.2, released 9 November 2026) whose graph store is "Postgres, always". The online docs describe that newer line, not the pinned one. This is a new question for the map.

## Terms

- **Graph**: the nodes and edges a Jac app saves (here, decks, their card holdings and `Card` nodes). Jac saves each node or edge as an **anchor**, one row per object.
- **L1, L2, L3**: Jac's three storage tiers. L1 is a dictionary of anchors in the process's memory. L2 is an optional cache. L3 is the durable store. (`jaclang/runtimelib/memory.jac`, module docstring.)
- **jac-scale**: a separate PyPI package and Jac plugin that replaces the built-in server with FastAPI and Uvicorn, and adds MongoDB, Redis, single sign-on and Kubernetes deployment.
- **Scale to zero**: the host stops the process when no requests arrive and starts it again on the next request. The first request after a stop waits for a **cold start**.
- **WAL**: SQLite's write-ahead log mode, where changes go to a side file (`-wal`) before the main database file.

## What Jac recommends for deployment (pinned version)

1. The built-in guide says: "Production serving is jac-scale's job: `pip install jac-scale`". It then describes `jac start` flags, database backends and Kubernetes. It names no other hosting target. (`uv run jac guide jac-sv-deploy`; file `jaclang/cli/skills/jac-sv-deploy.md`.)
2. Without jac-scale, `jac start` runs Python's standard-library `HTTPServer`, bound to `0.0.0.0`, in one process that handles one request at a time. (`jaclang/jac0core/impl/runtime.impl.jac` lines 1927-1934; `jaclang/runtimelib/impl/server.impl.jac` line 1825.) This is what the repo runs today: `mcp_server.jac` `start_web` gets the server class from `Jac.get_api_server_class()` and starts it on a thread.
3. With jac-scale, the same command serves through FastAPI and Uvicorn, one worker per process. (`jac_scale/jserver/impl/jfast_api.impl.jac` lines 148-170; `jac_scale/plugin.jac` `create_server` and `get_api_server_class` hooks.)
4. `jac start app.jac --scale` deploys to a Kubernetes cluster and provisions MongoDB and Redis there as StatefulSets. `--build` builds and pushes a Docker image first. `jac destroy` deletes the namespace and its volumes. (`jac guide jac-sv-deploy`.) Jac ships no Dockerfile for a hand-built container at this version; the image build is part of the Kubernetes path.
5. The online tutorial for a local server (https://docs.jaseci.org/tutorials/production/local/) and the jac-scale reference (https://docs.jaseci.org/reference/plugins/jac-scale/) describe the same ladder: `jac run` is "one user, one process, local store", `jac start` is "N users, one machine", `jac start --scale` is "N users, M machines, Kubernetes". These pages now describe a newer Jac than the pin (they use `[scale.*]` config keys where 0.16.7 uses `[plugins.scale.*]`), so details differ.
6. `jac start` exits when its standard input closes, so a server started in the background needs `< /dev/null`; the guide says containers and systemd do this already. This repo starts the server with `jac run mcp_server.jac` instead, which is not affected. (`jac guide jac-sv-deploy`.)
7. The built-in server has no setting for the port other than `--port`, and no setting for allowed browser origins: single-process `jac start` hardwires `allow_origins=['*']`. (`jac guide jac-sv-deploy`, "Observability and coordination".) This repo reads its ports from `KP_PORT` and `KP_HTTP_PORT` (`mcp_server.jac`).

## What stores the graph in each setup

| Setup | Graph (L3) | Cache (L2) | Users table | Where |
|---|---|---|---|---|
| `jac start`, no plugin (this repo today) | SQLite, WAL mode | none | SQLite | `<JAC_DATA_PATH or app dir>/.jac/data/`: `<project-name>.db` for the graph, `main.db` for users |
| jac-scale, no `MONGODB_URI` | SQLite (falls back to jaclang's `SqliteMemory`) | none | SQLite | `.jac/data/anchor_store.db`, relative to the working directory (`shelf_db_path`) |
| jac-scale with `MONGODB_URI` | MongoDB | Redis if `REDIS_URL` is set | MongoDB | external servers |
| `jac start --scale` (Kubernetes) | MongoDB StatefulSet with a persistent volume | Redis | MongoDB | inside the cluster |

Sources: `jaclang/runtimelib/impl/utils.impl.jac` `get_db_path`; `jaclang/runtimelib/impl/server.impl.jac` `UserManager.postinit`; `jaclang/runtimelib/impl/memory.impl.jac` lines 700-712 and 1909-1960; `jac_scale/impl/memory_hierarchy.main.impl.jac` lines 42-90; `jac_scale/plugin_config.jac` line 88; `jac guide jac-sv-deploy` ("SQLite at `.jac/data/` by default ... Set `MONGODB_URI` ... for MongoDB and `REDIS_URL` for the Redis cache tier - required for multi-replica deployments").

Other facts about storage:

- `JAC_DATA_PATH` moves both SQLite files: they go to `$JAC_DATA_PATH/.jac/data/`. `scripts/dev.sh` already sets it, and `shared_graph.jac` `graph_dir` puts `writer.lock` in the same folder. A host volume mounted at that path would hold the graph, the users table and the lock.
- jac-scale's SQLite fallback uses a different file name (`anchor_store.db`) from the built-in server (`<project-name>.db`), so installing jac-scale would not pick up an existing graph by itself.
- A storage plugin can supply another L3 through the `get_persistent_memory` hook (`jaclang/runtimelib/impl/memory.impl.jac` lines 1940-1960). The pinned jaclang contains a SQLAlchemy backend for SQLite, Postgres or MySQL only inside `jac eject`, a command that converts the project to a FastAPI app; its own docstring says "Single-writer; use jac-scale to scale." (`jaclang/cli/commands/eject_targets/backend.jac` lines 15-19.) No Postgres backend for an un-ejected app ships at this version.
- Schema changes do not delete saved data on either SQLite or MongoDB; rows that cannot be loaded are moved to a quarantine table and managed with `jac db`. (`jac guide jac-sv-persistence`.)
- Jac documents no backup or restore procedure. On SQLite the data is the files in `.jac/data/` (including the `-wal` and `-shm` side files while the process runs).

## Can the app scale to zero and come back without losing the graph?

Facts that bear on it:

1. Every graph change reaches SQLite when the request commits, inside one `BEGIN IMMEDIATE` transaction that either applies fully or rolls back. (`jaclang/runtimelib/impl/memory.impl.jac` `SqliteMemory.apply`, lines 1023-1120.) `shared_graph.jac` `run_walker` calls `Jac.commit()` after every MCP tool's walker.
2. The connection uses `journal_mode=WAL` and `synchronous=NORMAL` (same file, lines 710-712). SQLite's documentation says that in this mode a committed transaction survives the application being killed, and the database cannot be corrupted by a crash; only a power loss or operating-system crash can roll back the most recent commits. (https://www.sqlite.org/pragma.html#pragma_synchronous)
3. On start, the process reads anchors from SQLite on demand and keeps them in L1 for its lifetime. Nothing has to be rebuilt before the first request. (`TieredMemory.get`, same file, lines 1964-1983; `jaclang/runtimelib/impl/context.impl.jac` `ExecutionContext.postinit`.)
4. The writer lock is an `flock`, which the operating system releases when the process ends, so a stopped instance does not block the next start. (`shared_graph.jac` `acquire_graph_lock`.)
5. SQLite's WAL mode needs every process using the database to be on the same machine and does not work on a network filesystem. (https://www.sqlite.org/wal.html, "Disadvantages".) Whether a given host's volume is a local disk is a question for the host (ticket 92).
6. Jac's own scale-to-zero support exists only on Kubernetes: jac-scale's KEDA autoscaler has `idle_replicas`, described as "Set to 0 for scale-to-zero". (`jac_scale/plugin_config.jac` lines 190-203.) Jac has nothing that stops or wakes a process on a platform service.

So the decks survive a stop and start when `.jac/data/` is on persistent local disk and exactly one instance runs. They are lost if the folder is on the container's own filesystem and the host replaces the container.

State that does not survive a stop: anything held in process memory. In this repo that is the in-memory MCP sessions of the streamable HTTP transport and the L1 cache. Whether a claude.ai connector reconnects cleanly after the server restarts was not tested.

## How long does a cold start take?

Not measured, and Jac publishes no figure. A cold start of `jac run mcp_server.jac` does these things, in order:

1. Starts Python and imports jaclang. `uv run jac --version` takes about 0.4 seconds on the development machine.
2. Loads the app's Jac modules. Whether a fresh container must compile them from source or can reuse a compiled cache under `.jac/` was not checked.
3. Runs `check_catalogue`, which opens `data/catalog.sqlite` read-only and compares its schema with the code (`cards.sv.jac` line 87, `catalog/store.py`). The server refuses to start if the catalogue is missing or built by older code (`README.md`). Building it means downloading about 26 MB from MTGJSON and "takes a few seconds" (`README.md`).
4. Takes the graph lock and looks up the guest root in SQLite.
5. Builds the browser bundle with Vite if `.jac/client/dist/client.*.js` does not exist, and skips the build if it does. (`jaclang/runtimelib/impl/server.impl.jac` `JacAPIServer.start`, lines 2608-2630.) The build needs the `bun` tool, which Jac downloads into `.jac/bin/` when it is not installed (`jaclang/runtimelib/client/bun_installer.jac`), and the npm packages in `jac.toml`. `jac build` produces the bundle ahead of time.
6. Starts the MCP server.

`scripts/dev.sh` waits up to 120 seconds for `/healthz` before it gives up, which is an upper bound someone chose, not a measurement. The earlier spike's "about 7 seconds" (`docs/spikes/s02-jac-go-no-go.md`) was for a design that rebuilt a catalogue graph in memory at start; the current app keeps the catalogue in SQLite and does not do that.

## Can more than one process write the graph?

- **Built-in server on SQLite: no.** Each process keeps its own L1 copy of every anchor it has read and returns that copy on later reads without looking at SQLite again (`TieredMemory.get`). The pinned jaclang has no mechanism for one process to tell another that an anchor changed. A second process therefore reads stale data and writes fields from its stale copy. The guide says "Multi-replica + SQLite = corruption/confusion. Going past one replica requires `MONGODB_URI` (+ Redis for cache/locks)" and "`threading.Lock` only serializes one process" (`jac guide jac-sv-deploy`). This matches what the repo found and guards against with `writer.lock` (`README.md`, `shared_graph.jac`).
- **jac-scale on SQLite: not supported either.** jac-scale gives each request its own L1 (`jac_scale/impl/context.impl.jac`), which removes the stale-copy problem inside one machine, but the guide's warning above still applies and SQLite still needs all processes on one machine.
- **jac-scale on MongoDB with Redis: yes.** This is the only multi-process setup the pinned version documents. Writers detect conflicting changes by version and the losing request is replayed. Each write sends an invalidation over a Redis channel so other processes drop their stale L1 copy; without Redis there is "no cross-pod coherence" beyond each request re-reading. (`jac_scale/l1_invalidation.jac`; `jac_scale/memory_hierarchy.jac`; https://docs.jaseci.org/reference/plugins/jac-scale-persistence/.)
- Inside one process, concurrent requests are safe: SQLite access is serialised by a lock, and a write whose request read a node that another request has since changed is rolled back as a `WriteConflict` (`SqliteMemory.apply` and `_merge_write`). `shared_graph.jac` `run_walker` also holds its own lock around each MCP walker.

## What this means for this repo

**The single-writer graph on local disk.** It fits a host that runs exactly one instance with a persistent local volume mounted where `JAC_DATA_PATH` points. It rules out two instances at once, including a brief overlap while a new version starts before the old one stops: the second instance would exit at `acquire_graph_lock`. Running more than one instance at the pinned version means adding jac-scale and a MongoDB server (and Redis).

**The SQLite catalogue.** It is opened read-only (`file:...?mode=ro`, `catalog/store.py` line 22), so it places no limit on the number of processes and needs no persistence: it can be rebuilt from MTGJSON at any time. It must exist, with the schema the code expects, before the server starts. Whether it is built into the image or onto a volume is already an open item on the map; Jac has no opinion on it because the catalogue is plain Python and SQLite outside Jac's storage.

**The MCP server in the same process.** It shares the process because of the single-writer rule, and it stays valid on a one-instance host. The process listens on two ports: the web app and REST on `KP_PORT` (bound to all interfaces by Jac) and MCP on `KP_HTTP_PORT` (bound to `KP_HTTP_HOST`, default `127.0.0.1`). The MCP transport rejects requests whose `Host` header is not listed in `KP_HTTP_ALLOWED_HOSTS` (`mcp_server.jac` `serve_http`). `shared_graph.jac` and `mcp_server.jac` reach into the built-in runtime directly (`ExecutionContext(_parent=...)`, `Jac.get_user_manager`, `Jac.get_api_server_class`). Installing jac-scale replaces all three through plugin hooks (`jac_scale/plugin.jac` lines 945-985), so that code would need rework and retesting.

## Options the facts leave open

1. **Stay on the built-in server and SQLite, one instance, persistent volume.** No new Jac dependency. Scale to zero depends only on the host keeping the volume and running one instance. Limits: one request at a time in the web server, no second instance, no documented backup beyond copying the files.
2. **Add jac-scale with MongoDB (and Redis).** The only route at the pinned version to more than one process, and to jac-scale's other features (ticket 90 covers its sign-in). Costs: a MongoDB server to host and pay for, a different web server, rework of `shared_graph.jac` and `mcp_server.jac`, and a move of the existing SQLite graph. Jac automates this only on Kubernetes.
3. **Move to current Jac (0.39.x).** See the next section. The graph store becomes Postgres, which platform services commonly offer, and several server workers are supported. The size of the migration is unknown.

## The pinned version is no longer the current Jac

- PyPI's newest `jaclang` is 0.16.7, uploaded 2026-06-19; newest `jac-scale` is 0.2.31, uploaded 2026-06-25; newest `jaseci` is 2.3.28, uploaded 2026-06-19. (https://pypi.org/pypi/jaclang/json, https://pypi.org/pypi/jac-scale/json, https://pypi.org/pypi/jaseci/json.)
- The upstream repository's releases continue as a self-contained `jac` binary: v0.39.2 on 2026-11-09. (https://github.com/jaseci-labs/jaseci/releases; install instructions in https://github.com/jaseci-labs/jaseci/blob/main/README.md.)
- In that line, "Scale ships inside `jaclang` -- there is no `jac-scale` package to install", the server is started with `jac run`, and "**Backend:** Postgres, always. An embedded per-project server provisions automatically (zero setup); set `JAC_DB_URL` ... to use an external server". (https://github.com/jaseci-labs/jaseci/blob/main/jac/jaclang/cli/skills/jac-sv-deploy.md)
- Its persistence reference says the embedded Postgres keeps one cluster per machine under `~/.cache/jac/pg/main`, that each request is one `SERIALIZABLE` transaction with the loser of a race replayed, and that this "holds identically for a single local process and a multi-pod deployment sharing one database". (https://github.com/jaseci-labs/jaseci/blob/main/jac/jaclang/cli/docs/reference/persistence.md)
- Its release notes say an unset worker count now starts one worker process per CPU core, and that apps keeping state in module globals "now get one copy per worker" unless `count = "1"`. (https://github.com/jaseci-labs/jaseci/blob/main/jac/jaclang/cli/docs/community/release_notes/jaclang.md)
- It publishes a container base image, `jaseci/jaclang`, with the binary and the embedded Postgres baked in, described as "the pod base for scale deployments". (https://github.com/jaseci-labs/jaseci/blob/main/docker/jaclang.Dockerfile) Its deploy command, `jac scale deploy`, still targets Kubernetes only.
- The online docs at docs.jaseci.org and jaclang.org describe this newer line. Where they disagree with `jac guide` in this repo's virtual environment, `jac guide` is right for the pinned version.

## What could not be confirmed

- The cold start time of this app, on any machine. It needs one timed start in a clean container with the bundle and catalogue already built.
- Whether a fresh container recompiles the app's Jac modules on every start or can carry a compiled cache in the image.
- Whether jac-scale 0.2.31 works with this repo's `jac-client==0.3.25` and its direct use of the runtime; it was read, not installed. Its metadata lists no `jaclang` requirement at 0.2.31 (0.2.30 requires `jaclang>=0.16.7`).
- Whether a claude.ai connector recovers by itself when the MCP server restarts and its in-memory sessions are gone.
- What moving this codebase from jaclang 0.16.7 to Jac 0.39.x involves (renamed commands, config keys, plugin hooks, the SQLite-to-Postgres move of saved decks). Only the docs and release notes were read.
- Whether the built-in server behaves correctly when the host sends a stop signal in the middle of a request. Committed requests are safe (see above); the request in flight was not examined.
