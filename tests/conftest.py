"""Point the app at a catalogue built from the small MTGJSON fixture, and give
tests that start Jac processes a database of their own."""

import os
import socket
from pathlib import Path

import pytest

from catalog import store
from catalog.ingest import build, load_atomic, load_oracle_tags
from tests.databases import fresh_database

FIXTURE = Path(__file__).parent / "fixtures" / "atomic_small.json"
TAGS_FIXTURE = Path(__file__).parent / "fixtures" / "oracle_tags_small.jsonl"


@pytest.fixture(autouse=True)
def fixture_catalog(tmp_path, monkeypatch):
    path = tmp_path / "catalog.sqlite"
    build(load_atomic(FIXTURE), path, tags=load_oracle_tags(TAGS_FIXTURE))
    monkeypatch.setenv("KP_CATALOG", str(path))
    store.reset()
    yield path
    store.reset()


def _free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


@pytest.fixture(scope="session")
def test_postgres(tmp_path_factory):
    """A Postgres server for this test run, from the distribution current Jac
    embeds, listening on 127.0.0.1 only. Jac's own embedded server for this
    worktree listens on a Unix socket, which `JAC_DB_URL` cannot name."""
    from jaclang.data.pgembed import PgRuntime

    server = PgRuntime(
        data_dir=str(tmp_path_factory.mktemp("postgres") / "data"),
        port=_free_port(), tcp=True, database="postgres",
    )
    server.ensure()
    yield server
    server.stop()


@pytest.fixture
def jac_db_url(test_postgres, monkeypatch):
    """A fresh database for one test, as a `JAC_DB_URL`. It is set in this
    process's environment too, so in-process clients read the same graph as
    the processes the test starts."""
    with fresh_database(test_postgres) as url:
        monkeypatch.setenv("JAC_DB_URL", url)
        yield url


# Seconds per test file on CI (run 44915907844), for the files that take 10 s
# or more. A file not listed here counts as `DEFAULT_SECONDS`.
FILE_SECONDS = {
    "test_front_door_process.py": 122, "test_dev_script.py": 107,
    "test_ui_smoke.py": 103, "test_commander.py": 48, "test_mcp.py": 46,
    "test_deck_io.py": 43, "test_seed.py": 41, "test_browser_session.py": 39,
    "test_catalog_schema.py": 39, "test_front_door.py": 31,
    "test_legality.py": 30, "test_api.py": 29, "test_backup_script.py": 29,
    "test_mana_curve.py": 17, "test_hosted_auth.py": 17,
    "test_rate_limits.py": 11, "test_deck_cards.py": 10,
}
DEFAULT_SECONDS = 2


def _cost(name):
    return FILE_SECONDS.get(Path(name).name, DEFAULT_SECONDS)


def split_into_shards(files, count):
    """Split test file names into `count` shards of similar total time: the
    slowest first, each into the shard with the least so far. The split depends
    only on the names, so every CI job computes the same one."""
    shards = [[] for _ in range(count)]
    totals = [0] * count
    for cost, name in sorted((-_cost(f), f) for f in files):
        lightest = totals.index(min(totals))
        shards[lightest].append(name)
        totals[lightest] -= cost
    return shards


def parse_shard(spec):
    """`KP_SHARD`'s value `<k>/<n>` as (k, n), with k from 1 to n."""
    try:
        k, n = (int(x) for x in spec.split("/"))
    except ValueError:
        raise pytest.UsageError(f"KP_SHARD must look like 2/4, not {spec!r}") from None
    if not 1 <= k <= n:
        raise pytest.UsageError(f"KP_SHARD={spec}: the shard number must be from 1 to {n}")
    return k, n


def pytest_collection_modifyitems(config, items):
    """With `KP_SHARD=<k>/<n>` (k from 1), run only the k-th of n shards of the
    test files; the CI matrix runs one shard per job. Without it, run all."""
    spec = os.environ.get("KP_SHARD")
    if not spec:
        return
    k, n = parse_shard(spec)
    files = sorted({str(item.path) for item in items})
    shard_files = set(split_into_shards(files, n)[k - 1])
    kept, dropped = [], []
    for item in items:
        (kept if str(item.path) in shard_files else dropped).append(item)
    config.hook.pytest_deselected(items=dropped)
    items[:] = kept
