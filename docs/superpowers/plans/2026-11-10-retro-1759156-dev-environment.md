# Retro 1759156: Dev Environment Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A worktree has one command to run the app (`jac script up`), one to check it (`jac script check`), a current catalogue built offline from a shared download cache, an automated UI smoke test in CI, written coding standards, a one-command board move, and an `AGENTS.md` that points at all of these instead of `jac create` boilerplate.

**Architecture:** Everything here is environment, not app behaviour. The project's commands are exposed through the `jac` CLI: plain `jac check` / `jac run` / `jac browse` where Jac already covers the case, and `[scripts]` entries in `jac.toml` (run as `jac script <name>`, listed by `jac script --list`) where it doesn't. Logic too big for a one-liner lives in `scripts/*.sh`, which the `[scripts]` entries call. `jac script` cannot pass arguments (`jac script x a b` → "unrecognized arguments", checked 2026-11-10), so the one command that needs them, the board move, stays a direct script call. No justfile or other task runner. Around that: a cache layer in `catalog/ingest.py`, one new pytest module, and steering docs. `scripts/dev.sh` is the single way to start the app: it runs `mcp_server.jac` in HTTP mode, so one process serves the web app on the worktree's port and MCP on the next port up (two Jac processes must never share a graph). The UI smoke test starts the app through `dev.sh` on a free port, so it tests the same launch path a human uses. All `AGENTS.md`/`README.md` edits are collected in one late task so the parallel tasks never conflict on them.

**Tech Stack:** `jac script` (`[scripts]` in `jac.toml`; see `uv run jac guide jac-config`), Bash (`scripts/*.sh`), Python 3.12 (`catalog/`, pytest), `jac browse` (headless browser over CDP, ships with jaclang 0.16.7) for the UI smoke test, `mcp==2.3.0` client for the MCP Apps view check, `gh` CLI + GraphQL for the board script, GitHub Actions.

**Spec:** GitHub issue #78 (Retro 1759156) and all of its sub-issues: #79 (one dev, check and steering entry point per worktree), #80 (automated UI smoke test), #81 (shared catalogue download cache), #82 (`CODING_STANDARDS.md`), #83 (dispatch workers into Orca worktrees), #84 (gh Projects-classic workaround and board script), #85 (jac run report echo, session length). All seven sub-issues are in this branch.

## Global Constraints

- Read issues with `gh issue view N --json title,body,comments` (or `gh api repos/DaveParr/knowledge-pool/issues/N`); bare `gh issue view N` exits 1 with the Projects (classic) error (#84). Verified working on 2026-11-10.
- Never use `pkill -f` / `killall` in any script or step: `dev.sh down` stops only the process group in its pidfile (#79).
- `dev.sh` must not start a second Jac process against the same graph: it runs `mcp_server.jac` (which serves the web app itself), never `jac start` alongside it (`mcp_server.jac` docstring).
- `jac script check` runs exactly, stopping at the first failure: `jac check *.jac`, `scripts/jac_test.sh`, `pytest tests` — and CI calls it instead of its own steps (#79). All 23 top-level `.jac` files pass `jac check` today (verified 2026-11-10). `scripts/jac_test.sh` stays because `jac test` exits 0 when a test raises.
- Commands go through the `jac` CLI: no wrapper where a `jac` subcommand already does the job, a `jac.toml` `[scripts]` entry where it doesn't, and a direct `scripts/*.sh` call only when arguments are needed (`scripts/board.sh`). No justfile, Makefile or new task runner.
- `jac script` runs its command through a shell from the project root, finds `jac.toml` from a subfolder, and returns the command's exit code (checked 2026-11-10). Run it as `uv run jac script <name>` (or with the venv active), so entries can call `jac`, `pytest` and `python` directly.
- Script names, fixed: `check`, `up`, `down`, `status`, `catalogue`, `test-ui`.
- Shared download cache default: `${XDG_CACHE_HOME:-$HOME/.cache}/knowledge-pool/`, overridable with `KP_CACHE`; re-download only when a cached file is older than a set age (#81). Default age: 7 days.
- Board: project `PVT_kwHOAH-e384Boo56`, Status field `PVTSSF_lAHOAH-e384Boo56zhnIDMM`, options Backlog `f75ad846`, Ready `61e4505c`, In progress `47fc9ee4`, In review `df73e18b`, Done `98236657` (read from the board 2026-11-10).
- No new runtime or dev dependency (`pyproject.toml` unchanged). If the UI smoke test truly needs one, add it with `uv add --dev`, pinned.
- Before editing any `.jac` file, run `uv run jac guide jac-core-cheatsheet` (AGENTS.md). This plan should need no `.jac` changes.
- Use the repo's `writing-for-agents` skill (`.claude/skills/writing-for-agents/`) when writing `AGENTS.md`, `CODING_STANDARDS.md` and the run skill: point at commands, don't restate what `--help` already says.

## Parallelism

Sub-issues map to tasks; waves can run in parallel Orca worktrees (#83's own advice) and merge back to this branch in order.

| Wave | Task | Sub-issue | Depends on |
|---|---|---|---|
| 1 | 1 `jac.toml` `[scripts]` + CI | #79 | — |
| 1 | 2 `dev.sh` | #79 | — |
| 1 | 3 Download cache + `--if-stale` | #81 | — |
| 1 | 4 `CODING_STANDARDS.md` | #82 | — |
| 1 | 5 `board.sh` | #84 | — |
| 2 | 6 UI smoke test | #80 | 1, 2 |
| 2 | 7 `dev.sh up` builds the catalogue | #81 | 2, 3 |
| 3 | 8 Steering: `AGENTS.md`, README, run skill, `qa-mvp.md` | #79, #81, #82, #83, #84, #85 | all |

Wave-1 tasks must not touch `AGENTS.md`, `README.md` or `docs/`; Task 8 owns those. Task 1 owns `jac.toml`: it adds all six `[scripts]` entries at once, so no other task edits that file. Entries whose target doesn't exist yet (`up`/`down`/`status` before Task 2, `catalogue` before Task 3, `test-ui` before Task 6) fail until their task lands; each of those tasks ends by running its entry.

## Review Focus

- **Two worktrees run `dev.sh up` at once and their derived ports collide.** The second must take the next free pair, not fail or attach to the other worktree's server. → Task 2's `test_up_skips_a_taken_port`.
- **`dev.sh up` run twice, or after the server died.** A live pidfile means "already running, here's the URL" (exit 0, no second process); a dead pid means clean the pidfile and start. → Task 2's `test_up_twice_reuses_the_running_server` and `test_up_after_a_crash_starts_again`.
- **`dev.sh down` with children.** `mcp_server.jac` may spawn helpers (the client build); `down` must leave nothing listening on either port. → Task 2's `test_down_frees_both_ports`.
- **Offline with a stale cache.** A cached file older than the max age, and the re-download fails: use the stale file with a warning on stderr rather than fail, so a new worktree still gets a catalogue offline. → Task 3's `test_stale_cache_is_used_when_download_fails`.
- **`--if-stale` against a current catalogue must not touch it** (no rebuild, no download), so `dev.sh up` stays fast. → Task 3's `test_if_stale_leaves_a_current_catalogue_alone`.

---

## File Structure

- Modify `jac.toml` — a `[scripts]` section: the project's command list.
- Modify `.github/workflows/test.yml` — call `jac script check`; make the UI test mandatory in CI.
- Create `scripts/dev.sh` — `up|down|status|port` per worktree.
- Create `tests/test_dev_script.py` — `dev.sh` lifecycle tests.
- Modify `catalog/ingest.py` — shared cache, max age, `--if-stale`.
- Create `tests/test_ingest_cache.py` — cache and `--if-stale` tests.
- Create `CODING_STANDARDS.md` — the review judgement calls.
- Create `scripts/board.sh` — `board.sh <issue> <status>`.
- Create `tests/test_ui_smoke.py` — browser smoke test of the web app and the `deck_table.html` view.
- Modify `AGENTS.md`, `README.md`, `docs/qa-mvp.md`; create `.claude/skills/run-knowledge-pool/SKILL.md`.

---

### Task 1: `jac.toml` `[scripts]` and CI (#79)

**Files:**
- Modify: `jac.toml` (new `[scripts]` section; read `uv run jac guide jac-config` first)
- Modify: `.github/workflows/test.yml` (replace the "Type-check", "Run walker tests" and "Run pytest suite" steps)

**Interfaces:**
- Produces (Tasks 2, 3, 6, 7 and 8 rely on these names; no other task edits `jac.toml`):

```toml
[scripts]
check = "jac check *.jac && scripts/jac_test.sh && pytest tests"
up = "scripts/dev.sh up"
down = "scripts/dev.sh down"
status = "scripts/dev.sh status"
catalogue = "python -m catalog.ingest --if-stale"
test-ui = "pytest tests/test_ui_smoke.py -v"
```

- [ ] **Step 1: Add the `[scripts]` section** above to `jac.toml`.

- [ ] **Step 2: Check the list**

Run: `uv run jac script --list`
Expected: all six names with their commands.

- [ ] **Step 3: Run the check**

Run: `uv run jac script check`
Expected: `23 passed` from `jac check`, `jac test` passes, pytest passes; exit 0.

- [ ] **Step 4: Prove it fails at the first stage** — add a type error (`echo 'with entry { x: int = "a"; }' > zz_broken.jac`), run `uv run jac script check; echo $?`, expect a non-zero exit with no `jac test` output after the `jac check` errors; delete `zz_broken.jac`.

- [ ] **Step 5: CI calls it** — in `test.yml`, replace the three steps with one step `name: Check`, `run: uv run jac script check`. Keep the install and artifact-upload steps as they are.

- [ ] **Step 6: Commit**

```bash
git add jac.toml .github/workflows/test.yml
git commit -m "Expose the project's commands as jac scripts; CI runs jac script check (#79)"
```

---

### Task 2: `scripts/dev.sh` (#79)

**Files:**
- Create: `scripts/dev.sh`
- Test: `tests/test_dev_script.py`

**Interfaces:**
- Produces:
  - `scripts/dev.sh up` — starts the app if not running, waits for `GET /healthz` on the web port (timeout 120 s, exit 1 with the log's tail on timeout), then prints exactly these lines:
    `web: http://127.0.0.1:<P>`
    `mcp: claude mcp add --transport http knowledge-pool-<slug> http://127.0.0.1:<P+1>/mcp`
    `log: <state dir>/server.log`
  - `scripts/dev.sh down` — stops it; exit 0 if nothing was running.
  - `scripts/dev.sh status` — prints the same three lines and exits 0 if running; prints `not running` and exits 3 otherwise.
  - `scripts/dev.sh port` — prints the web port `<P>` only (the running one, else the one `up` would choose).
  - Environment: `KP_DEV_DIR` (state dir, default `<repo>/.jac/dev`), `KP_DEV_PORT` (force the web port), `KP_CATALOG` (default `<repo>/data/catalog.sqlite`), `JAC_DATA_PATH` (default `<repo>`). Each is used as given if already set.
  - State files in `KP_DEV_DIR`: `server.pid` (process-group id), `port`, `server.log`.
  - Task 7 adds a catalogue step to `up` before the server starts; leave a clearly named function `ensure_catalogue` that is a no-op for now.

Port choice: `<slug>` is the worktree directory's basename. Base port = `8100 + 2 * ($(printf %s "$REPO" | cksum | cut -d' ' -f1) % 400)`; if the base or base+1 is taken (test with bash `/dev/tcp`), step by 2 until a free pair is found. `KP_DEV_PORT` skips derivation.

Start command: `setsid env KP_PORT=$P KP_TRANSPORT=http KP_HTTP_PORT=$((P+1)) KP_CATALOG=… JAC_DATA_PATH=… uv run jac run mcp_server.jac >>server.log 2>&1 &`, pidfile holds `$!` (the session/group leader). `down` sends `TERM` to `-<pgid>`, waits up to 10 s for both ports to close, then `KILL`s the group.

Verify the MCP path first: start once by hand with `KP_TRANSPORT=http` and confirm `/mcp` answers (FastMCP's default streamable path); if not, use the path it does serve in the `mcp:` line.

- [ ] **Step 1: Write the failing tests** in `tests/test_dev_script.py`. A helper `dev(*args, env)` runs `scripts/dev.sh` with `KP_DEV_DIR=tmp_path/"dev"`, `KP_CATALOG=fixture_catalog`, `JAC_DATA_PATH=tmp_path`, and a fixture that always runs `dev.sh down` at teardown.

```python
def test_up_serves_the_app_and_prints_its_urls(fixture_catalog, tmp_path):
    out = dev("up", env=...).stdout
    port = int(dev("port", env=...).stdout)
    assert f"web: http://127.0.0.1:{port}" in out
    assert f"http://127.0.0.1:{port + 1}/mcp" in out
    assert urlopen(f"http://127.0.0.1:{port}/healthz").status == 200

def test_up_twice_reuses_the_running_server(...):
    # same port both times, same pid in server.pid
def test_up_after_a_crash_starts_again(...):
    # kill -9 the group behind dev.sh's back; `up` starts a new one (new pid, healthz 200)
def test_up_skips_a_taken_port(...):
    # bind a socket on the port `dev.sh port` would choose; `up` picks a different port, healthz 200
def test_down_frees_both_ports(...):
    # after `down`: server.pid gone, nothing accepts on port or port+1, `status` exits 3 with "not running"
def test_status_when_not_running_exits_3(...):
```

- [ ] **Step 2: Run to verify they fail**

Run: `uv run pytest tests/test_dev_script.py -v`
Expected: FAIL (`scripts/dev.sh` not found).

- [ ] **Step 3: Implement `scripts/dev.sh`** as specified in Interfaces. `chmod +x`. Usage message on unknown subcommand, exit 2.

- [ ] **Step 4: Run to verify they pass**

Run: `uv run pytest tests/test_dev_script.py -v`
Expected: 6 passed.

- [ ] **Step 5: Manual check through the jac scripts against the real catalogue** — `uv run jac script up`, open the printed web URL with `uv run jac browse open <url>` and `snapshot` (Decks view renders), `uv run jac script status` (exit 0), `uv run jac script down`. Confirm `pgrep -f mcp_server.jac` lists nothing from this worktree.

- [ ] **Step 6: Commit**

```bash
git add scripts/dev.sh tests/test_dev_script.py
git commit -m "Add scripts/dev.sh: one app per worktree on its own port (#79)"
```

---

### Task 3: Shared download cache and `--if-stale` (#81)

**Files:**
- Modify: `catalog/ingest.py` (`DEFAULT_DOWNLOAD`, `DEFAULT_TAGS_DOWNLOAD`, `main`; `download` and `download_oracle_tags` stay as the fetchers)
- Test: `tests/test_ingest_cache.py`

**Interfaces:**
- Produces:
  - `cache_dir() -> Path` — `$KP_CACHE`, else `$XDG_CACHE_HOME/knowledge-pool`, else `~/.cache/knowledge-pool`.
  - `MAX_AGE_DAYS = 7`
  - `cached(dest: Path, fetch: Callable[[Path], Path], max_age_days: float) -> Path` — returns `dest` if it exists and is younger than the max age; otherwise calls `fetch(dest)`; if that raises `OSError` (includes `URLError`) and `dest` exists, prints `Using cached <dest> (<n> days old): download failed: <err>` to stderr and returns `dest`; if `dest` does not exist, re-raises.
  - `cache_paths() -> tuple[Path, Path]` — `(cache_dir()/"mtgjson"/"AtomicCards.json.xz", cache_dir()/"scryfall"/"oracle-tags.jsonl.gz")`.
  - CLI: `--max-age-days N` (default `MAX_AGE_DAYS`); `--if-stale` — exit 0 printing `Catalogue <path> is current` without downloading or building when the catalogue exists and `store.check_current()` passes; otherwise build as normal. Import `store` inside `main` (store imports ingest at module level).
  - Task 7 calls: `uv run python -m catalog.ingest --if-stale`.

- [ ] **Step 1: Write the failing tests** in `tests/test_ingest_cache.py`, with `KP_CACHE` set to `tmp_path` and `fetch` replaced by a stub that writes a file and counts calls (use `os.utime` to age files). Patch `ingest.download` / `ingest.download_oracle_tags` with stubs that write `tests/fixtures/atomic_small.json` xz-compressed (`lzma.compress`) and `oracle_tags_small.jsonl` gzip-compressed to `dest`, so the cached names keep their real `.xz`/`.gz` suffixes and the loaders open them unchanged. Expose the two cache paths as `cache_paths() -> tuple[Path, Path]` (atomic, tags) so tests and Task 7 never repeat the names.

```python
def test_fresh_cache_is_reused_without_downloading(tmp_path, monkeypatch): ...  # fetch calls == 0
def test_old_cache_is_downloaded_again(...): ...                              # aged 8 days -> fetch calls == 1
def test_stale_cache_is_used_when_download_fails(..., capsys): ...            # fetch raises URLError -> returns dest; "download failed" in stderr
def test_missing_cache_and_failed_download_raises(...): ...
def test_cache_dir_honours_kp_cache_then_xdg(...): ...
def test_if_stale_leaves_a_current_catalogue_alone(fixture_catalog, ...): ...  # mtime unchanged, no fetch, "is current" printed
def test_if_stale_builds_a_missing_catalogue(...): ...                        # KP_CATALOG -> nonexistent path; after main(["--if-stale"]) it exists and check_current() passes
def test_if_stale_rebuilds_a_stale_catalogue(...): ...                        # use tests/old_catalog.py to make an old-schema catalogue
```

- [ ] **Step 2: Run to verify they fail**

Run: `uv run pytest tests/test_ingest_cache.py -v`
Expected: FAIL (`cache_dir`/`cached` not defined).

- [ ] **Step 3: Implement** `cache_dir`, `cached`, the two cache paths and the two CLI flags in `catalog/ingest.py`. Update the module docstring's usage block with `--if-stale` and `--max-age-days`. `--source` / `--tags-source` still bypass the cache.

- [ ] **Step 4: Run to verify they pass**

Run: `uv run pytest tests/test_ingest_cache.py tests/test_catalog.py tests/test_catalog_schema.py -v`
Expected: all pass.

- [ ] **Step 5: Real run** — `KP_CATALOG=/tmp/x.sqlite uv run python -m catalog.ingest` (downloads into `~/.cache/knowledge-pool/`), then run it again with the network unavailable to you or with `time`: the second build uses the cache and takes about 7 s. Then `uv run jac script catalogue` (the `--if-stale` entry from Task 1) prints "is current".

- [ ] **Step 6: Commit**

```bash
git add catalog/ingest.py tests/test_ingest_cache.py
git commit -m "Keep catalogue downloads in a shared cache; add --if-stale (#81)"
```

---

### Task 4: `CODING_STANDARDS.md` (#82)

**Files:**
- Create: `CODING_STANDARDS.md`

**Interfaces:**
- Produces: the file at the repo root; the repo's `code-review` skill's Standards reviewer reads it. Task 8 links it from `AGENTS.md` and drops the README card count.

- [ ] **Step 1: Write it** — short (under ~40 lines), one rule per bullet, each with this repo's example from #82:
  - Share helpers instead of copying them: deck formats share `deckformats/base.py`.
  - Tests and docs derive counts from fixtures; never hard-code a fixture's size (README's "214 cards" vs 298; `tests/test_catalog.py` in #73).
  - Use the named constant when one exists (`CHECKED_ZONES`, `ZONES`), never a hand-written copy of its list (`["main", "companion"]` in `legality.sv.jac`).
  - Share fixtures (symlink or one source), don't copy fixture files (#75).
  - A test name states what it asserts (`test_<subject>_<expected behaviour>`), as in `test_down_frees_both_ports`.
  - One line on scope: these are the judgement calls a reviewer checks every time; mechanical checks belong in `jac script check`.

- [ ] **Step 2: Check the examples are still true** — `grep -n '"main", "companion"' legality.sv.jac`; `grep -rn '214\|298' README.md tests/*.py`; `ls -l tests/fixtures` for the #75 symlinks. Reword any example that no longer matches the code.

- [ ] **Step 3: Commit**

```bash
git add CODING_STANDARDS.md
git commit -m "Add CODING_STANDARDS.md for recurring review findings (#82)"
```

---

### Task 5: `scripts/board.sh` (#84)

**Files:**
- Create: `scripts/board.sh`

**Interfaces:**
- Produces: `scripts/board.sh <issue-number> <status>` where `<status>` is one of `Backlog`, `Ready`, `In progress`, `In review`, `Done` (case-insensitive; `in-progress` / `in-review` accepted). Prints `#<n> -> <Status>`. Exit 2 with the valid list on an unknown status; exit 1 if the issue is not on the board.

The IDs in Global Constraints are hard-coded at the top of the script as named variables. Find the item id with one GraphQL query on the issue's `projectItems(first: 20) { nodes { id project { id } } }` filtered to the board's project id; then `gh project item-edit --id <item> --project-id PVT_kwHOAH-e384Boo56 --field-id PVTSSF_lAHOAH-e384Boo56zhnIDMM --single-select-option-id <option>`. Use `gh api graphql`, never `gh issue view` (Projects classic error).

- [ ] **Step 1: Write the script**; `chmod +x`.

- [ ] **Step 2: Check argument handling without touching the board**

Run: `scripts/board.sh 78 nonsense; echo $?`
Expected: the valid statuses listed, `2`.

- [ ] **Step 3: Check a real move, then put it back** — the issue says not to change the board during planning, but implementation may: move #78 to its current status (read it first from `gh project item-list 7 --owner DaveParr --format json`), so the call is a no-op on the board. Expected: `#78 -> <current status>`, exit 0.

- [ ] **Step 4: Commit**

```bash
git add scripts/board.sh
git commit -m "Add scripts/board.sh to move issues on the Knowledge Pool board (#84)"
```

---

### Task 6: Automated UI smoke test (#80)

**Files:**
- Create: `tests/test_ui_smoke.py`
- Modify: `.github/workflows/test.yml` (env `KP_REQUIRE_BROWSER: "1"` on the Check step; a browser install step only if Step 1 shows CI needs one)

**Interfaces:**
- Consumes: `scripts/dev.sh up|down|port` with `KP_DEV_DIR`, `KP_DEV_PORT`, `KP_CATALOG`, `JAC_DATA_PATH` (Task 2); `jac script check` runs it via pytest, and `jac script test-ui` runs it alone (Task 1).
- Produces: `tests/test_ui_smoke.py` with a module fixture `app` that runs `dev.sh up` with a free `KP_DEV_PORT`, the `fixture_catalog` and a throwaway `JAC_DATA_PATH`, yields the web and MCP URLs, and runs `dev.sh down` at teardown. Browser calls go through a helper `browse(*args) -> str` running `jac browse -s kp-smoke-<port> ...` (own session so it never touches an agent's browser) and closing the session at teardown. Output and a final `screenshot` go to `test-artifacts/ui_smoke/` on failure, like `tests/test_mcp.py`'s log.

`app` is module-scoped but `fixture_catalog` is function-scoped and autouse: build the module's own catalogue with `catalog.ingest.build` from the same fixtures (via `tmp_path_factory`) rather than widening `conftest.py`.

- [ ] **Step 1: Check a browser can launch** — `uv run jac browse -s probe open about:blank && uv run jac browse -s probe close`. If it fails, find what `jac browse` needs (`jac browse --help`, `jac guide --search browse`) and note it; on `ubuntu-latest`, Chrome is preinstalled — add an install step only if `jac browse` can't find it. The test skips with that reason when no browser launches, unless `KP_REQUIRE_BROWSER=1`, when it fails.

- [ ] **Step 2: Write the failing tests**

```python
def test_build_a_deck_through_the_web_app(app):
    # open web URL; fill "New deck name" with "Smoke Burn"; click "Create deck"
    # open "Smoke Burn"; fill "Search cards" (placeholder "Card name, type or rules text") with "Lightning Bolt"
    # click "Add " for Lightning Bolt (main deck)
    # assert snapshot text contains "Main deck", "Lightning Bolt"
    # click the Lightning Bolt line to expand it; assert "deals 3 damage" appears
    # assert "Not legal" is shown (1 card is under the 60-card minimum) and a 60-card message is listed

def test_deck_table_view_renders_a_real_deck_show_result(app):
    # call MCP deck_show over streamable HTTP at the app's mcp URL for the "Smoke Burn" deck
    #   (create it via deck_create/deck_edit if this test runs alone)
    # open file://<repo>/ui/deck_table.html in the browser
    # eval: window.postMessage({jsonrpc: "2.0", method: "ui/notifications/tool-result",
    #        params: {structuredContent: <deck_show structuredContent>}}, "*")
    # assert the rendered table contains "Lightning Bolt" and its count
```

Find refs with `snapshot`, but click/fill by visible label or placeholder (the strings above are in `frontend.cl.jac`, `deck_detail.cl.jac`, `card_search.cl.jac`) so the test survives layout changes. Use `jac browse wait` before each assertion, never sleeps. If the view ignores messages whose `event.source` isn't `window.parent`, load it inside a one-line host page written to `tmp_path` that iframes it and forwards the message.

- [ ] **Step 3: Run to verify they fail** — run before the steps are filled in, or against a deliberately wrong label.

Run: `uv run pytest tests/test_ui_smoke.py -v`
Expected: FAIL on the first assertion (not a skip, not a setup error).

- [ ] **Step 4: Fill in the steps until both pass**

Run: `uv run pytest tests/test_ui_smoke.py -v`
Expected: 2 passed, in under ~2 minutes.

- [ ] **Step 5: Prove it catches a break** — temporarily make `search_cards` in `cards.sv.jac` return `[]` (the #65 failure), rerun, expect `test_build_a_deck_through_the_web_app` to FAIL; revert.

- [ ] **Step 6: CI** — set `KP_REQUIRE_BROWSER: "1"` on the Check step (plus a browser step if Step 1 needed one). Run `uv run jac script test-ui`, then `uv run jac script check`: all green.

- [ ] **Step 7: Commit**

```bash
git add tests/test_ui_smoke.py .github/workflows/test.yml
git commit -m "Add an automated UI smoke test of the web app and deck_table view (#80)"
```

---

### Task 7: `dev.sh up` builds the catalogue from the cache (#81)

**Files:**
- Modify: `scripts/dev.sh` (`ensure_catalogue`)
- Test: `tests/test_dev_script.py`

**Interfaces:**
- Consumes: `uv run python -m catalog.ingest --if-stale` (Task 3); `ensure_catalogue` hook in `dev.sh up` (Task 2).
- Produces: `dev.sh up` leaves a current catalogue at `$KP_CATALOG` before starting the server; a build failure stops `up` with the ingest's error and a non-zero exit, before any server starts.

- [ ] **Step 1: Write the failing test**

```python
def test_up_builds_a_missing_catalogue_from_the_cache(tmp_path, monkeypatch):
    # KP_CACHE = tmp_path/"cache" pre-filled with the fixture AtomicCards and oracle tags,
    # stamped fresh; KP_CATALOG = tmp_path/"catalog.sqlite" (absent)
    # `dev.sh up` succeeds; the catalogue exists; healthz 200; no network used
```

Pre-filling the cache depends on the cache file names chosen in Task 3; use `uv run python -c "from catalog.ingest import cache_paths; ..."` or import `cache_paths` in the test rather than repeating the names.

- [ ] **Step 2: Run to verify it fails**

Run: `uv run pytest tests/test_dev_script.py::test_up_builds_a_missing_catalogue_from_the_cache -v`
Expected: FAIL (server refuses to start: no catalogue).

- [ ] **Step 3: Implement `ensure_catalogue`** — run `uv run python -m catalog.ingest --if-stale` with `KP_CATALOG` exported; on failure print `dev.sh: could not build the catalogue (see above)` and exit 1.

- [ ] **Step 4: Run the whole file**

Run: `uv run pytest tests/test_dev_script.py -v`
Expected: 7 passed.

- [ ] **Step 5: Through the jac script** — with no `data/catalog.sqlite` in the worktree and a warm cache, `uv run jac script up` builds the catalogue and starts the app; `uv run jac script down`.

- [ ] **Step 6: Commit**

```bash
git add scripts/dev.sh tests/test_dev_script.py
git commit -m "dev.sh up builds a missing or stale catalogue from the shared cache (#81)"
```

---

### Task 8: Steering — `AGENTS.md`, README, run skill, `qa-mvp.md` (#79, #81, #82, #83, #84, #85)

**Files:**
- Modify: `AGENTS.md`, `README.md`, `docs/qa-mvp.md`
- Create: `.claude/skills/run-knowledge-pool/SKILL.md`

**Interfaces:**
- Consumes: every script and flag above, by the names in their Interfaces blocks.

- [ ] **Step 1: Rewrite `AGENTS.md`** (use the `writing-for-agents` skill). Keep the Jac pointers (`jac guide`, `jac guide jac-core-cheatsheet`). Replace the generic "Validate your work" section with pointers, one line each:
  - Commands: `uv run jac script --list` lists this repo's commands; don't restate the list in `AGENTS.md`. (#79)
  - Validate: `jac script check` (what CI runs). (#79)
  - Run: `jac script up|status|down` — never `jac start` by hand, never `pkill -f`. (#79)
  - Catalogue: built from `~/.cache/knowledge-pool/` by `jac script up` or `jac script catalogue`; don't hunt for `AtomicCards.json.xz`. (#81)
  - Fixtures: grow `tests/fixtures/atomic_small.json` with `scripts/fixture_cards.py`. (#79)
  - Review standards: `CODING_STANDARDS.md`. (#82)
  - Orchestrated work: dispatch workers into Orca worktrees (or run on the feature branch one agent at a time), not the built-in `isolation: worktree`. (#83)
  - GitHub: read issues with `gh issue view N --json title,body,comments`; update PR bodies with `gh api -X PATCH repos/DaveParr/knowledge-pool/pulls/N -F body=@file`; move board cards with `scripts/board.sh <issue> <status>`. (#84)
  - Jac gotcha: `jac run` prints every walker `report` to stdout; wrap walker calls in `redirect_stdout` as `seed.jac`'s `walk` helper does. (#85)

- [ ] **Step 2: README** — Setup: replace the "point `KP_CATALOG` at the main checkout's" tip with the shared cache and `--if-stale` (#81). Run: lead with `uv run jac script up`. Test: `uv run jac script check`, and replace "214 real cards" with wording that carries no count (#82). Layout: add the `[scripts]` section of `jac.toml` (`jac script --list`), `scripts/dev.sh`, `scripts/board.sh`.

- [ ] **Step 3: `docs/qa-mvp.md`** — it still names branch `27-claude-mcp` and old test counts. Replace sections 1–3 with "`uv run jac script up`, then `uv run jac script check`"; keep the per-slice manual checks if they still match the app, else delete the file and drop its README link. Decide by running through section 4 against `jac script up`.

- [ ] **Step 4: Run skill** — `.claude/skills/run-knowledge-pool/SKILL.md`: frontmatter `name: run-knowledge-pool`, a description that triggers on "run/start/test the app" in this repo; body: `uv run jac script up`, open the web URL with `jac browse`, `uv run jac script down` when finished. Under 20 lines.

- [ ] **Step 5: Verify every pointer** — run each command named in `AGENTS.md` and the skill once (`uv run jac script --list`, `jac script check`, `jac script up/status/down`, `jac script catalogue`, `scripts/board.sh 78 nonsense`, `gh issue view 78 --json title`); check `grep -rn 'check\.sh\|27-claude-mcp\|214 real' README.md AGENTS.md docs .claude .github --exclude-dir=superpowers` returns nothing.

- [ ] **Step 6: Commit**

```bash
git add AGENTS.md README.md docs/qa-mvp.md .claude/skills/run-knowledge-pool/SKILL.md
git commit -m "Point AGENTS.md, README and a run skill at the new dev, check and board scripts (#78)"
```

## Done when

- `uv run jac script --list` shows `check`, `up`, `down`, `status`, `catalogue`, `test-ui`; no justfile or `scripts/check.sh` exists.
- `jac script check` passes locally and is the CI's only test step; CI runs the UI smoke test with a browser.
- `jac script up` in a fresh worktree with no `data/` gives a running app and an MCP line, offline when the cache is warm.
- `AGENTS.md` points at check, dev, catalogue, fixtures, standards, Orca dispatch, the gh workaround, the board script and the report-echo gotcha.
- Not done in this branch, by design: #83's user-level `CLAUDE.md`/memory copy (outside the repo — Dave can add one line by hand), and #85's "re-check session length after these land", which is an observation for the next retro, not code.
