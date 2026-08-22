# Research: Does Railway's managed Postgres support pgvector?

**Issue:** [DaveParr/knowledge-pool#11](https://github.com/DaveParr/knowledge-pool/issues/11) (parent: #1, "wayfinder" architecture-mapping exercise)

**Question:** Does Railway's managed Postgres offering support the `pgvector` extension — can it be enabled, which version is available, and what's its performance profile at the scale of the MTGJSON card corpus (tens of thousands of card/printing rows, each with an embedding)?

**Live web access in this session:** Yes — WebSearch and WebFetch were both available and used for every claim below. Where a claim could not be confirmed against a primary source, it is explicitly flagged.

---

## Upfront answer

1. **Does it work?** Yes, but not on the default "Postgres" template out of the box. Railway's standard Postgres template does **not** ship with pgvector pre-installed and does not expose `CREATE EXTENSION vector;` as an installable extension on the default image. Railway instead publishes **separate, dedicated pgvector templates** (built directly from the official `pgvector/pgvector` Docker Hub image, e.g. `pgvector/pgvector:pg17`) that you deploy instead of the base Postgres template. Once deployed, pgvector is present in the image and still needs to be turned on per-database with `CREATE EXTENSION IF NOT EXISTS vector;`.
2. **Which version?** Railway currently offers templates pinned to Postgres 17 and Postgres 18 (`pgvector-pg17`, `pgvector-pg18`), each built on the corresponding official `pgvector/pgvector` image tag. The pgvector extension version itself is not pinned/displayed on the Railway template page — it is whatever ships in that upstream Docker image tag at build time. Separately, pgvector's own repository is currently at v0.8.6 (July 2026) and supports Postgres 13+.
3. **Performance at tens-of-thousands-of-rows scale?** Good. The closest available real benchmark (60K rows, 784 dimensions) shows pgvector's HNSW index building in under 1.5 minutes with a 234MB index and strong recall/QPS tradeoffs versus IVFFlat. At this scale, index choice is not a bottleneck either way — HNSW is the more defensible default given its better speed/recall tradeoff at query time and workable build time, and the corpus is small enough that even brute-force scans would likely be tolerable for a v1.

**Net effect on the architecture decision:** This validates the "single Postgres + pgvector, no separate vector DB" decision, with one important caveat — it requires deploying Railway's dedicated pgvector template (or a custom Dockerfile) rather than the default Postgres service, and a decision needs to be made about which Postgres major version to standardize on. See Caveats below.

---

## Findings with sources

### 1. Railway's own documentation

- **Source:** [docs.railway.com/databases/postgresql](https://docs.railway.com/databases/postgresql) (fetched live)
  - States Railway's Postgres image is an "SSL-enabled Postgres image" based on "the official Postgres image from Docker Hub" — does not name a specific version number on this page.
  - States explicitly: *"In an effort to maintain simplicity in the default templates, we do not plan to add extensions to the PostgreSQL templates covered in this guide."*
  - States that for popular extensions "like PostGIS and Timescale, there are several options in the template marketplace," and separately lists dedicated deployments for TimescaleDB, PostGIS, TimescaleDB+PostGIS, **and pgvector**.
  - Advises advanced users who need a custom extension set to "fork the Railway postgres-ssl repository to customize it to your needs."

- **Source:** [railway.com/deploy/qcuy_M](https://railway.com/deploy/qcuy_M) — Railway's "pgvector-pg17" template page (fetched live)
  - States the template provides "PostgreSQL v17 with the pgvector extension pre-installed."
  - The underlying image is `pgvector/pgvector:pg17` — i.e. the official upstream pgvector Docker image, not a Railway-authored build.
  - Start command shown: `/bin/sh -c "unset PGPORT; docker-entrypoint.sh postgres --port=5432"` — a thin wrapper around the standard pgvector entrypoint.
  - pgvector's own version number is **not** stated on this page.
  - A search also surfaced a sibling template `pgvector-pg18` (`railway.com/deploy/pgvector-pg18`), confirming Postgres 18 is also offered as a pgvector option, and a generic `pgvector-latest` template.

- **Source:** [station.railway.com/questions/enable-pgvector-extension-for-postgre-sql-e861e033](https://station.railway.com/questions/enable-pgvector-extension-for-postgre-sql-e861e033) — Railway's own community help forum, with a reply from Railway staff/moderator "uxuz" (fetched live)
  - Confirms directly: *"enabling pgvector isn't as straightforward"* on the default Postgres service, and the `vector` extension does not appear in the installable-extensions list there.
  - Staff-recommended path: deploy Railway's pgvector template and migrate existing data over via `pg_dump`/restore, rather than trying to add the extension to an existing default Postgres deployment.
  - A community workaround was also posted: change a Railway Postgres service's source image to `pgvector/pgvector:pg17` directly, then run `CREATE EXTENSION vector;`.
  - This is a support-forum thread, not formal documentation, but it is Railway's own official help channel and includes a Railway staff reply, so it is treated here as a primary source for "how this actually behaves in practice," while noting forum threads can go stale.

**Conclusion for Section 1:** Confirmed from primary Railway sources: pgvector is not on the default Postgres template; Railway ships purpose-built templates (currently pg17 and pg18 variants) that pre-install it; `CREATE EXTENSION vector;` is still required afterward.

### 2. Railway's GitHub repos for Postgres images/templates

- **Source:** [github.com/railwayapp-templates/postgres-ssl](https://github.com/railwayapp-templates/postgres-ssl) (fetched live) — this is the repo Railway's own docs point to as the source of the default Postgres template/image.
  - README confirms: *"The Dockerfiles contained in this repository start with the official Postgres image as base"* — i.e. it is `postgres:<version>` from Docker Hub with Railway's `init-ssl.sh` layered in via `docker-entrypoint-initdb.d/`, to force SSL on by default. It is **not** a custom Postgres fork/build, just the stock image plus an SSL bootstrap script.
  - The repo carries per-version Dockerfiles (Dockerfile.13 through Dockerfile.18, plus a Dockerfile.upgrade), with image tags including `:17`, `:17.6`, `:16`, `:16.10`, `:15`, etc.
  - Its `:latest` tag **currently points to PostgreSQL 16** — i.e., absent an explicit pin, a newly-deployed default Railway Postgres service is most likely landing on Postgres 16 as of this research (Aug 2026), even though 17 and 18 builds exist in the same repo and are used by name in the pgvector templates.
  - No pgvector is present in this repo — this confirms the default Postgres template genuinely does not carry pgvector, consistent with Section 1.

- **Source:** [github.com/railwayapp-templates](https://github.com/railwayapp-templates) organization listing (fetched via search) shows ~126 repos, including `postgres`, `postgres-ssl`, `postgres-s3-backups`, `timescale-postgis-ssl`, `postgres-duckdb-ssl`, and `expressjs-postgres`, but **no first-party `pgvector`-named repo** was found under the official `railwayapp-templates` org. This suggests the pgvector template Railway serves at `railway.com/deploy/qcuy_M` is likely a thin template-marketplace wrapper directly around the upstream `pgvector/pgvector` Docker Hub image rather than a Railway-maintained Dockerfile — consistent with the start-command evidence in Section 1. **This inference could not be fully verified live** (I could not locate a definitive Railway-owned Dockerfile source repo for the pgvector template specifically), so treat "Railway builds its pgvector image straight from `pgvector/pgvector:pgXX` with no custom modifications" as a reasonable but not 100%-confirmed conclusion.
  - Note: several *unofficial, community* Railway pgvector templates also exist (e.g. `daimajia/railway-pgvector`, using `ankane/pgvector:v0.4.4` — an old, pre-0.5 version; `stewartwebb/railway-postgis-pgvector`). These are not Railway's own and should not be relied on for this project; they're mentioned only to flag that search results mix official and community templates and version currency varies a lot between them.

**Conclusion for Section 2:** Confirmed: the default Railway Postgres image is stock `postgres:<version>` + an SSL init script, no extensions added. Likely but not fully confirmed: Railway's official pgvector template is a near-unmodified wrapper around the upstream `pgvector/pgvector` Docker image.

### 3. pgvector's own repository/docs

- **Source:** [github.com/pgvector/pgvector](https://github.com/pgvector/pgvector) — README (fetched live via raw content) and [tags page](https://github.com/pgvector/pgvector/tags) (fetched live)
  - Current version: **v0.8.6** (tagged 2026-07-29), with a steady release cadence back through v0.8.0 (2024-10-30) → v0.8.1 (2025-09-05) → v0.8.2 (2026-02-25) → v0.8.3 → v0.8.4 → v0.8.5 → v0.8.6. (Note: the GitHub "Releases" tab itself reports no formal Release objects published — version history had to be read from the Tags page instead.)
  - Supported Postgres versions: **Postgres 13+** ("pgvector supports Postgres 13+" for building/installing on Linux and Mac).
  - Index types: **HNSW** and **IVFFlat**.
    - HNSW: "creates a multilayer graph. It has better query performance than IVFFlat (in terms of speed-recall tradeoff), but has slower build times and uses more memory." Key params: `m` (max connections per layer, default 16), `ef_construction` (candidate list size at build time, default 64), and query-time `hnsw.ef_search` (default 40; higher = better recall, slower).
    - IVFFlat: "divides vectors into lists, and then searches a subset of those lists... has faster build times and uses less memory than HNSW, but has lower query performance." Key params: `lists` (recommended `rows / 1000` for up to 1M rows, `sqrt(rows)` for over 1M), and query-time `ivfflat.probes` (default 1).
  - Dimension limits: `vector` type indexable up to 2,000 dimensions; `halfvec` up to 4,000; `bit` up to 64,000; `sparsevec` up to 1,000 non-zero elements. (Common embedding models — e.g. OpenAI `text-embedding-3-small` at 1536 dims — fit comfortably within the `vector` index limit.)
  - Build-time guidance: indexes build "significantly faster when the graph fits into `maintenance_work_mem`"; for HNSW, "it's faster to create an index after loading your initial data" (i.e. bulk-load rows first, then build the index, rather than building it empty and inserting incrementally).
  - The README does **not** publish its own fixed benchmark numbers for a specific row count — it explicitly defers to comparing approximate vs. exact search on your own data/hardware rather than citing preset recall/throughput figures.

**Conclusion for Section 3:** Confirmed directly from the pgvector repo: HNSW and IVFFlat both exist, Postgres 13+ is supported, current version is 0.8.6, and the project itself does not publish authoritative recall/latency numbers — those had to come from third-party benchmarks (below).

### 3b. Third-party benchmark data (secondary sources, used only to fill the gap left by pgvector's own docs)

These are **not primary sources** — flagged clearly as such — but are the closest available data points at the requested scale (tens of thousands of rows):

- **Source:** [Jonathan Katz, "An early look at HNSW performance with pgvector"](https://jkatz05.com/post/postgres/pgvector-hnsw-performance/) (fetched live). Katz is a long-standing PostgreSQL/pgvector contributor (not the HNSW implementation's author specifically), so this is a well-informed secondary source, not the pgvector project's own published data.
  - On the `mnist-784-euclidean` dataset — **60,000 vectors, 784 dimensions**, the closest tested scale to MTGJSON's tens-of-thousands-of-rows corpus:
    - IVFFlat build time: 0.19–1.56 minutes depending on list count.
    - HNSW build time: 0.87–1.45 minutes across `m=12` to `m=24`.
    - HNSW index size: 234 MB at this scale (constant across the tested `m` configurations).
    - IVFFlat had marginally higher raw QPS than HNSW at this size but "at a great expense with recall" — Katz's conclusion is that HNSW gave "very strong performance / recall characteristics on this smaller data set," and that build speed and index size are both very manageable well under 100K rows.
- **Source:** [Mastra, "Benchmarking pgvector RAG performance across different dataset sizes"](https://mastra.ai/blog/pgvector-perf) (fetched live) — tested 10K/100K/500K/1M vectors at 64/384/1024 dimensions.
  - Found recall stayed "typically 100%" for datasets above ~1,000 vectors — well within the range of MTGJSON's tens-of-thousands of rows.
  - At 500K vectors / 64 dims, median query latency was ~60–70ms; this is a considerably larger dataset than the MTGJSON case, so actual latency at tens-of-thousands of rows should be comfortably lower.
  - This post did not report HNSW build times or hardware specs, so it's a secondary corroboration of "recall is fine at this scale," not a full replacement for the Katz data point above.

**Conclusion for Section 3b (not primary-source-verified, general LLM/industry knowledge plus the two blogs above):** at tens of thousands of rows, both HNSW and IVFFlat build in well under a couple of minutes on modest hardware, indexes are small (low hundreds of MB), and recall for either index type is very high (approaching exact-search results) as long as reasonable defaults (or a small bump to `ef_search`/`probes`) are used. This is squarely in the regime where pgvector's stated tradeoffs (HNSW = slower build/more memory but better query recall-speed; IVFFlat = faster build/less memory but weaker recall-speed) barely bite — the dataset is small enough that either index type, or even a sequential scan, would perform adequately for a first version.

### 4. What Postgres major version does Railway deploy by default?

- From `railwayapp-templates/postgres-ssl` (primary source, Section 2): the repo's `:latest` tag **currently resolves to Postgres 16**, though Dockerfiles for 13 through 18 all exist in the same repo and are used by Railway's other templates (e.g., the pgvector templates use pg17/pg18 explicitly by tag).
- This means: if this project deploys Railway's **default** Postgres template, it will most likely land on **Postgres 16** unless a specific version is pinned. If it deploys Railway's **pgvector** template instead (required to get pgvector at all — see Section 1), it will land on whichever version that template is pinned to — currently **17 or 18**, per the two variants found (`pgvector-pg17`, `pgvector-pg18`).
- Both 16, 17, and 18 are within pgvector's supported range (13+), so this is not a blocking compatibility issue either way — but it does mean the project's actual running Postgres major version will differ depending on which template is chosen, which matters for anyone reasoning about Postgres-version-specific SQL features elsewhere in the codebase.

---

## Caveats and risks

1. **Must use the pgvector template, not the default Postgres template.** Railway's own docs and its own support forum both confirm the standard Postgres service does not expose `vector` as an installable extension. The project must deploy the dedicated `pgvector-pg17`/`pgvector-pg18` (or equivalent) template from day one, or plan a `pg_dump`/restore migration later — Railway staff explicitly recommend the latter path if you started on the default template and need to switch.
2. **`CREATE EXTENSION vector;` is still a manual, per-database step**, even on the pgvector-flavored template — it is pre-installed in the image, not pre-enabled in the database. This needs to be part of whatever migration/bootstrap tooling the FastAPI backend runs on first deploy (e.g. an Alembic migration or init script), not assumed to already be active.
3. **Version pinning / drift risk.** Railway's pgvector templates are thin wrappers around the upstream `pgvector/pgvector:pgXX` Docker Hub image. Neither Railway's docs nor the template page states which exact pgvector version ships inside a given tag, and it was not possible to fully confirm from this session whether Railway auto-tracks upstream tag updates or freezes them at deploy time. Practically: pin/record the exact image digest actually deployed (visible in the Railway service's deployment settings) rather than assuming "pg17" always means the same pgvector version over time, and re-check after any Railway-initiated redeploy.
4. **Postgres major version differs by template choice.** Default Postgres template ≈ v16 currently; pgvector templates ≈ v17/v18. If other parts of the architecture (ORMs, raw SQL, other extensions) assume a specific Postgres major version, that needs to be reconciled against whichever template is actually chosen for this project.
5. **HNSW vs IVFFlat is a low-stakes choice at this corpus size.** MTGJSON's tens-of-thousands of card/printing rows are well below the scale (100K–1M+) where the two index types' tradeoffs (HNSW's slower build/more memory vs. IVFFlat's weaker recall-speed) become material. HNSW is the reasonable default (better recall-speed profile, and Katz's 60K-row benchmark shows build time under 1.5 minutes and a 234MB index at that scale) — but even IVFFlat, or no index at all, would likely be workable for a v1 at this row count.
6. **Official published benchmark data doesn't exist at exactly this scale.** pgvector's own README deliberately avoids fixed benchmark numbers, so the performance conclusions above rest on third-party blog benchmarks (Jonathan Katz, Mastra), not the pgvector project itself. These are credible (Katz is a recognized Postgres/pgvector contributor) but are secondary sources and should be re-validated with a quick local load test against the actual MTGJSON embedding pipeline before treating specific millisecond numbers as guaranteed.
7. **Community/unofficial Railway pgvector templates found in search results use stale pgvector versions** (e.g. `ankane/pgvector:v0.4.4`, from before HNSW support existed) — make sure the project's chosen template resolves to an official Railway template, not one of these older community forks, since some of the referenced performance/HNSW improvements only apply from pgvector 0.5.0 onward.

---

## Recommendation

**This validates the Postgres + pgvector decision for Railway specifically, with one adjustment to the deployment plan:** don't deploy Railway's generic/default Postgres template and expect to add pgvector later — deploy Railway's purpose-built pgvector template (pg17 or pg18 variant) from the start, since Railway's own staff describe retrofitting pgvector onto an already-running default Postgres service as a `pg_dump`-and-migrate exercise rather than a same-service upgrade. Functionally, at the MTGJSON corpus's scale (tens of thousands of rows), pgvector's performance profile is well inside its comfort zone for both index types, so there is no performance basis for reconsidering a dedicated vector database. The remaining open item is operational, not architectural: confirm exactly which pgvector version and Postgres major version the chosen Railway template resolves to at deploy time, and pin/record it, since neither Railway's docs nor its template page states this explicitly.
