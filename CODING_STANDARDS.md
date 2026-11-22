# Coding standards

The judgement calls reviewers check every time. Mechanical checks belong in `jac x check`, not here.

- **Share helpers, don't copy them.** The deck formats share `deckformats/base.py` (`basic_entry_problem`, `unparsed_note`); a new format imports from it.
- **Derive counts from fixtures.** Tests and docs never hard-code a fixture's size: README's "214 cards" went stale against the 298 in `tests/fixtures/atomic_small.json`, and `tests/test_catalog.py` did the same in #73.
- **Use the named constant when one exists.** `CHECKED_ZONES` (`commander.jac`) and `ZONES` and `ZONE_TITLES` (`zones.jac`) are the zone lists; a hand-written copy drifts, as `["main", "companion"]` does in `legality.jac` (#82).
- **Share fixtures, don't copy fixture files.** One source, reached by symlink: the `tests/fixtures/mtgjson_seed/` decks that point at their originals (#75).
- **A test name states what it asserts**: `test_<subject>_<expected behaviour>`, as in `test_down_frees_both_ports` (`tests/test_dev_script.py`).
