# Coding standards

The judgement calls reviewers check every time. Mechanical checks belong in `jac x check`, not here.

- **Share helpers, don't copy them.** The deck formats share `deckformats/base.py` (`basic_entry_problem`, `unparsed_note`); a new format imports from it.
- **Derive counts from fixtures.** Tests and docs never hard-code a fixture's size: README's "214 cards" went stale against the 298 in `tests/fixtures/atomic_small.json`, and `tests/test_catalog.py` did the same in #73.
- **Use the named constant when one exists.** `CHECKED_ZONES` (`commander.jac`) and `ZONES` and `ZONE_TITLES` (`zones.jac`) are the zone lists; a hand-written copy drifts, as `["main", "companion"]` does in `legality.jac` (#82).
- **Share fixtures, don't copy fixture files.** One source, reached by symlink: the `tests/fixtures/mtgjson_seed/` decks that point at their originals (#75).
- **A test name states what it asserts**: `test_<subject>_<expected behaviour>`, as in `test_down_frees_both_ports` (`tests/test_dev_script.py`).

## Jac at scale

Each graph read is a store round trip, so a walker's cost is its number of reads. From the #241 research; sources are the pinned `jac guide jac-node-edge-patterns` and `jac-sv-persistence`, and jaseci-labs/jac [#9914](https://github.com/jaseci-labs/jac/issues/9914) and [#9887](https://github.com/jaseci-labs/jac/issues/9887).

- **Read a node's edges once per call.** Why: a traversal is eager and re-reads the neighbourhood wherever it appears, so in a loop it runs per iteration. No traversal, `holdings()` or `owned()` in a loop over lines or cards; build a dict first, as `owned_search` (`collection.jac`) does. Source: `jac-node-edge-patterns`, "Reference semantics".

  ```jac
  # wrong: copies() reaches owned() and holdings() on every line (#241)
  for line in lines { n = copies(coll, line.oracle_id); }
  # right: one read, then dict lookups
  counts = {c.oracle_id: e.count for (e, c) in holdings(coll)};
  for line in lines { n = counts.get(line.oracle_id, 0); }
  ```

- **Ask the store, not the process.** Why: a predicate inside the reference runs as one query, and `jobj` finds by id in O(1), where a Jac loop pays for every row. For many lookups in one call, the rule above wins: N queries are still N round trips. Source: `jac-sv-persistence`, "Ask the store, not the process".

  ```jac
  # wrong: read every card, filter in Jac
  hits = [c for c in [coll ->:Owns:->] if c.oracle_id == oid];
  # right, for one card: the store filters, and the result is used where it is written
  if [coll ->:Owns:-> [?:Card, oracle_id == oid]] { ... }
  # by id: deck = jobj(deck_id);
  ```

- **A lookup helper that scans is for one lookup.** Why: callers copy its use into loops. Name scanners `find_…`, state O(n) in the docstring, and give callers that need many a map builder.

  ```jac
  # wrong: a scan named like a getter
  """The Owns edge and card for `oid`."""
  def owned(coll: Collection, oid: str) -> tuple[Owns, Card] | None { ... }
  # right: name and docstring say it scans; a map builder serves loops
  """O(n): scans every holding. For many lookups, build `count_map`."""
  def find_owned(coll: Collection, oid: str) -> tuple[Owns, Card] | None { ... }
  ```

- **Size tests to the failure.** Why: small fixtures hide O(lines × collection). Any walker that loops over user data has a test at about 10× the expected size, with a generous time bound.

  ```python
  # wrong: only the 25-card fixture
  def test_stamp_collection_counts_lines(): ...
  # right: 10x input, bounded
  def test_stamp_collection_stays_fast_at_ten_times_size(): ...  # assert elapsed < bound
  ```

- **Bound every wait in the request path, and log slow calls.** Why: a request timeout cannot stop a sync handler, so one slow call holds a lock and its thread while others queue. Bound the wait for the lock or queue, and log the name and duration of calls over a threshold. Source: #9914, #9887. Whether `LOCK` in `graph_runner.jac` should exist at all is #241's question, not a rule here.

  ```jac
  # wrong: unbounded wait, unmeasured
  with LOCK { attempt(); }
  # right: bounded wait, slow calls named
  if not LOCK.acquire(timeout=5.0) { return busy(); }
  try { t0 = time.monotonic(); attempt(); log_if_slow(name, time.monotonic() - t0); }
  finally { LOCK.release(); }
  ```
