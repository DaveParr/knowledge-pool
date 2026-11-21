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


# The slow files, in seconds, from the CI run that sized the shards. A file not
# listed here counts as `DEFAULT_SECONDS`.
FILE_SECONDS = {
    "test_ui_smoke.py": 93, "test_dev_script.py": 66, "test_commander.py": 53,
    "test_mcp.py": 40, "test_front_door_process.py": 36, "test_seed.py": 32,
    "test_deck_io.py": 29,
}
DEFAULT_SECONDS = 5


def shard_of(files, count):
    """Split test file names into `count` shards of similar total time: the
    slowest first, each into the shard with the least so far. The split depends
    only on the names, so every CI job computes the same one."""
    shards = [[] for _ in range(count)]
    totals = [0] * count
    for name in sorted(files, key=lambda f: (-FILE_SECONDS.get(Path(f).name, DEFAULT_SECONDS), f)):
        i = totals.index(min(totals))
        shards[i].append(name)
        totals[i] += FILE_SECONDS.get(Path(name).name, DEFAULT_SECONDS)
    return shards


def pytest_collection_modifyitems(config, items):
    """With `KP_SHARD=<k>/<n>` (k from 1), run only the k-th of n shards of the
    test files; the CI matrix runs one shard per job. Without it, run all."""
    spec = os.environ.get("KP_SHARD")
    if not spec:
        return
    k, n = (int(x) for x in spec.split("/"))
    files = sorted({str(item.path) for item in items})
    mine = set(shard_of(files, n)[k - 1])
    chosen = [item for item in items if str(item.path) in mine]
    config.hook.pytest_deselected(items=[i for i in items if str(i.path) not in mine])
    items[:] = chosen
