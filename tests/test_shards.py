"""The CI matrix splits pytest by test file (`KP_SHARD`); every file must run in exactly one shard."""

from pathlib import Path

from tests.conftest import FILE_SECONDS, split_into_shards

FILES = sorted(str(p) for p in Path(__file__).parent.glob("test_*.py"))


def test_split_into_shards_places_every_file_in_one_shard():
    shards = split_into_shards(FILES, 4)
    assert sorted(f for shard in shards for f in shard) == FILES


def test_split_into_shards_ignores_input_order():
    assert split_into_shards(FILES, 4) == split_into_shards(list(reversed(FILES)), 4)


def test_every_timed_file_still_exists():
    assert set(FILE_SECONDS) <= {Path(f).name for f in FILES}
