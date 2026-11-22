"""The CI matrix splits pytest by test file (`KP_SHARD`); every file must run in exactly one shard."""

from pathlib import Path

import pytest

from tests.conftest import FILE_SECONDS, parse_shard, split_into_shards

FILES = sorted(str(p) for p in Path(__file__).parent.glob("test_*.py"))


def test_split_into_shards_places_every_file_in_one_shard():
    shards = split_into_shards(FILES, 4)
    assert sorted(f for shard in shards for f in shard) == FILES


def test_split_into_shards_ignores_input_order():
    assert split_into_shards(FILES, 4) == split_into_shards(list(reversed(FILES)), 4)


def test_every_timed_file_still_exists():
    assert set(FILE_SECONDS) <= {Path(f).name for f in FILES}


def test_parse_shard_reads_shard_and_count():
    assert parse_shard("2/4") == (2, 4)


@pytest.mark.parametrize("spec", ["abc", "2", "2/4/6", "0/4", "5/4"])
def test_parse_shard_rejects_a_malformed_or_out_of_range_value(spec):
    with pytest.raises(pytest.UsageError):
        parse_shard(spec)
