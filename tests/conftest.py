"""Point the app at a catalogue built from the small MTGJSON fixture."""

from pathlib import Path

import pytest

from catalog import store
from catalog.ingest import build, load_atomic

FIXTURE = Path(__file__).parent / "fixtures" / "atomic_small.json"


@pytest.fixture(autouse=True)
def fixture_catalog(tmp_path, monkeypatch):
    path = tmp_path / "catalog.sqlite"
    build(load_atomic(FIXTURE), path)
    monkeypatch.setenv("KP_CATALOG", str(path))
    store.reset()
    yield path
    store.reset()
