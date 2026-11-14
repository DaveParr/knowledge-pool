"""Point the app at a catalogue built from the small MTGJSON fixture, and give
tests that start Jac processes a database of their own."""

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
