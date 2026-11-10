"""The download cache and `--if-stale`."""

import gzip
import lzma
import os
import sqlite3
import time
from pathlib import Path
from urllib.error import URLError

import pytest

from catalog import ingest, store
from tests import old_catalog

FIXTURES = Path(__file__).parent / "fixtures"
DAY = 86400


@pytest.fixture
def cache(tmp_path, monkeypatch):
    monkeypatch.setenv("KP_CACHE", str(tmp_path / "cache"))
    return tmp_path / "cache"


@pytest.fixture
def fetches(monkeypatch):
    """Replace both downloaders with stubs that write the fixtures; count calls."""
    calls: list[Path] = []

    def fake_download(dest: Path) -> Path:
        calls.append(dest)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(lzma.compress((FIXTURES / "atomic_small.json").read_bytes()))
        return dest

    def fake_tags(dest: Path) -> Path:
        calls.append(dest)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(gzip.compress((FIXTURES / "oracle_tags_small.jsonl").read_bytes()))
        return dest

    monkeypatch.setattr(ingest, "download", fake_download)
    monkeypatch.setattr(ingest, "download_oracle_tags", fake_tags)
    return calls


def _age(path: Path, days: float) -> None:
    then = time.time() - days * DAY
    os.utime(path, (then, then))


def _stub(calls):
    def fetch(dest: Path) -> Path:
        calls.append(dest)
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_text("new")
        return dest

    return fetch


def test_fresh_cache_is_reused_without_downloading(tmp_path):
    dest = tmp_path / "f"
    dest.write_text("old")
    calls: list[Path] = []
    assert ingest.cached(dest, _stub(calls), 7) == dest
    assert calls == []
    assert dest.read_text() == "old"


def test_old_cache_is_downloaded_again(tmp_path):
    dest = tmp_path / "f"
    dest.write_text("old")
    _age(dest, 8)
    calls: list[Path] = []
    assert ingest.cached(dest, _stub(calls), 7) == dest
    assert len(calls) == 1
    assert dest.read_text() == "new"


def test_missing_cache_is_downloaded(tmp_path):
    dest = tmp_path / "sub" / "f"
    calls: list[Path] = []
    ingest.cached(dest, _stub(calls), 7)
    assert len(calls) == 1


def test_stale_cache_is_used_when_download_fails(tmp_path, capsys):
    dest = tmp_path / "f"
    dest.write_text("old")
    _age(dest, 8)

    def fail(_dest):
        raise URLError("no network")

    assert ingest.cached(dest, fail, 7) == dest
    err = capsys.readouterr().err
    assert "Using cached" in err
    assert "download failed" in err
    assert dest.read_text() == "old"


def test_missing_cache_and_failed_download_raises(tmp_path):
    def fail(_dest):
        raise URLError("no network")

    with pytest.raises(URLError):
        ingest.cached(tmp_path / "f", fail, 7)


def test_cache_dir_honours_kp_cache_then_xdg(tmp_path, monkeypatch):
    monkeypatch.setenv("KP_CACHE", str(tmp_path / "kp"))
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path / "xdg"))
    assert ingest.cache_dir() == tmp_path / "kp"
    monkeypatch.delenv("KP_CACHE")
    assert ingest.cache_dir() == tmp_path / "xdg" / "knowledge-pool"
    monkeypatch.delenv("XDG_CACHE_HOME")
    assert ingest.cache_dir() == Path.home() / ".cache" / "knowledge-pool"


def test_cache_paths_keep_the_real_suffixes(cache):
    atomic, tags = ingest.cache_paths()
    assert atomic == cache / "mtgjson" / "AtomicCards.json.xz"
    assert tags == cache / "scryfall" / "oracle-tags.jsonl.gz"


def test_if_stale_leaves_a_current_catalogue_alone(fixture_catalog, cache, fetches, capsys):
    before = fixture_catalog.stat().st_mtime_ns
    assert ingest.main(["--if-stale"]) == 0
    assert fixture_catalog.stat().st_mtime_ns == before
    assert fetches == []
    assert "is current" in capsys.readouterr().out


def test_if_stale_builds_a_missing_catalogue(tmp_path, cache, fetches, monkeypatch):
    path = tmp_path / "new" / "catalog.sqlite"
    monkeypatch.setenv("KP_CATALOG", str(path))
    store.reset()
    assert ingest.main(["--if-stale"]) == 0
    assert path.exists()
    assert len(fetches) == 2
    store.reset()
    store.check_current()


def test_if_stale_rebuilds_a_stale_catalogue(fixture_catalog, cache, fetches):
    con = sqlite3.connect(fixture_catalog)
    old_catalog.drop_produced_mana(con)
    con.commit()
    con.close()
    store.reset()
    with pytest.raises(store.CatalogOutOfDate):
        store.check_current()
    assert ingest.main(["--if-stale"]) == 0
    assert len(fetches) == 2
    store.reset()
    store.check_current()


def test_second_build_uses_the_cache(tmp_path, cache, fetches):
    out = tmp_path / "a.sqlite"
    ingest.main(["--out", str(out)])
    ingest.main(["--out", str(out)])
    assert len(fetches) == 2


def test_source_flags_bypass_the_cache(tmp_path, cache, fetches):
    ingest.main(
        [
            "--source", str(FIXTURES / "atomic_small.json"),
            "--tags-source", str(FIXTURES / "oracle_tags_small.jsonl"),
            "--out", str(tmp_path / "a.sqlite"),
        ]
    )
    assert fetches == []
