# Coding standards

The judgement calls reviewers check every time. Mechanical checks belong in `jac x check`, not here.

- **Share helpers, don't copy them.** The deck formats share `deckformats/base.py` (`basic_entry_problem`, `unparsed_note`); a new format imports from it.
- **Derive counts from fixtures.** Tests and docs never hard-code a fixture's size: README's "214 cards" went stale against the 298 in `tests/fixtures/atomic_small.json`, and `tests/test_catalog.py` did the same in #73.
- **Use the named constant when one exists.** `CHECKED_ZONES` (`commander.jac`) and `ZONES` and `ZONE_TITLES` (`zones.jac`) are the zone lists; a hand-written copy drifts, as `["main", "companion"]` does in `legality.jac` (#82).
- **Share fixtures, don't copy fixture files.** One source, reached by symlink: the `tests/fixtures/mtgjson_seed/` decks that point at their originals (#75).
- **A test name states what it asserts**: `test_<subject>_<expected behaviour>`, as in `test_down_frees_both_ports` (`tests/test_dev_script.py`).

## Jac at scale

Each graph read is a store round trip, so the cost of a walker is the number of reads it makes. These come from the #241 research (a 60-line deck against a 200-card collection took ~20 s); the sources are the version-pinned `jac guide jac-node-edge-patterns` and `jac guide jac-sv-persistence`, and jaseci-labs/jac issues [#9914](https://github.com/jaseci-labs/jac/issues/9914) and [#9887](https://github.com/jaseci-labs/jac/issues/9887).

- **Read a node's edges once per call.** A traversal is eager and re-reads the neighbourhood wherever it appears, so inside a loop over lines or cards it runs once per iteration. No traversal, `holdings()` or `owned()` in such a loop: build a dict first. `owned_search` (`collection.jac`) is the model; `copies` → `owned()` → `holdings()` per deck line was #241.

  ```jac
  # wrong: holdings() per line, O(lines × collection)
  for line in lines { n = copies(coll, line.oracle_id); }
  # right: one read, then lookups
  counts = {c.oracle_id: e.count for (e, c) in holdings(coll)};
  for line in lines { n = counts.get(line.oracle_id, 0); }
  ```

- **Ask the store, not the process.** Put predicates, ordering and bounds inside the graph reference (`[coll ->:Owns:-> [?:Card, oracle_id == oid]]`, `[:20]`), and use `jobj` to find by id; filtering a full read in Jac pays for every row. For many lookups in one call the previous rule beats this one, since N predicate queries are still N round trips. Source: `jac-sv-persistence`, "Ask the store, not the process".

  ```jac
  # wrong: fetch every card, filter in Jac
  for c in [coll ->:Owns:->] { if c.oracle_id == oid { return c; } }
  # right, for one card: the store filters
  hit = [coll ->:Owns:-> [?:Card, oracle_id == oid]];
  ```

- **A lookup helper that scans is for one lookup.** Name it so (`find_…`), say O(n) in its docstring, and give callers that need many a map builder. `owned()` scans yet is named like a getter, so `stamp_collection` and `quest_list` called it per line.

  ```jac
  # wrong: a scanner named like a getter, called per line
  """The Owns edge and card for `oid`."""
  def owned(coll: Collection, oid: str) -> tuple[Owns, Card] | None { ... }
  # right: say it scans, and offer the map for loops
  """O(n): scans every holding. For many lookups use `count_map`."""
  def find_owned(coll: Collection, oid: str) -> tuple[Owns, Card] | None { ... }
  def count_map(coll: Collection) -> dict[str, int] { ... }
  ```

- **Size tests to the failure.** Any walker that loops over user data has a test at about 10× the expected size with a time bound. The fixtures are small (25-card collections), so nothing exercised the O(lines × collection) path; #241 asks for 500+ cards.

  ```python
  # wrong: passes at 25 cards, says nothing about 500
  def test_stamp_collection_counts_lines(): ...
  # right: big input, bounded time
  def test_stamp_collection_stays_fast_at_500_cards():
      ...; assert elapsed < 2.0
  ```

- **Bound every wait in the request path, and log slow calls.** A lock or queue a call waits on gets a timeout on the wait and a log of the name and duration of calls over a threshold. A request timeout cannot stop a sync handler (it keeps its thread and a cancelled call can still commit), so bound the wait for the lock, not the call (#9914, #9887). The slow call itself is fixed by the rules above. Whether `LOCK` in `graph_runner.jac` is needed at all is an open question on #241.

  ```jac
  # wrong: every request queues behind a slow one, unmeasured
  with LOCK { attempt(); }
  # right: bounded wait, slow calls named in the log
  if not LOCK.acquire(timeout=WAIT) { return try_again(); }
  try { t0 = time.monotonic(); attempt(); log_if_slow(name, time.monotonic() - t0); }
  finally { LOCK.release(); }
  ```
