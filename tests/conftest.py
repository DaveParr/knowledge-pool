"""Point the app at a catalogue built from the small MTGJSON fixture."""

from pathlib import Path

import pytest

from catalog import store
from catalog.ingest import build, load_atomic, load_oracle_tags

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
