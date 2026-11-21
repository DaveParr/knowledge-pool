"""The CI matrix splits pytest by test file (`KP_SHARD`); every file must run in exactly one shard."""

from pathlib import Path

from tests.conftest import shard_of

FILES = sorted(str(p) for p in Path(__file__).parent.glob("test_*.py"))


def test_every_test_file_is_in_exactly_one_shard():
    shards = shard_of(FILES, 4)
    assert sorted(f for shard in shards for f in shard) == FILES


def test_the_split_is_the_same_every_time():
    assert shard_of(FILES, 4) == shard_of(list(reversed(FILES)), 4)
