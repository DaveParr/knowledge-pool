# MVP QA: run it locally and check each P0 slice

This covers #23, #24, #26 and #27, plus the #25 spike.

## 1. Start the app and run the automated checks

```bash
scripts/install_jac.sh    # the Jac version jac.toml pins
jac install --dev
jac x up                  # builds the catalogue if missing or stale, prints the web and MCP URLs
jac x check               # type-check, walker tests and pytest: what CI runs
```

`jac x up` prints `web:`, `mcp:` and `log:` lines. Use the `web:` URL below wherever the checks say http://localhost:8000. Run `jac x down` when finished.

## 2. Manual QA

### #23 Jac PoC

- [ ] The Decks page loads and says "No decks yet."
- [ ] Type a name and press Create deck. The deck appears in the list.
- [ ] Press Create deck with a blank name. You get "A deck needs a name." and nothing is created.
- [ ] Run `jac x down` then `jac x up` again, and reload. The deck is still there.

### #24 Real cards in a deck

- [ ] `sqlite3 data/catalog.sqlite "select * from meta"` shows `mtgjson_version`, `mtgjson_date`, `ingested_at` and `card_count`.
- [ ] Open the deck. Search `lightning bolt`, which is a name search. Lightning Bolt is the first result.
- [ ] Search `whenever a creature dies`, which is a rules-text search. You get cards with that text, and the results feel instant.
- [ ] Press Add on a card twice. Its count shows 2.
- [ ] Change the count box to 4. The total updates.
- [ ] Press Remove. The card is gone.
- [ ] Add a card, restart the server (`down`, `up`), and reopen the deck. The card and its count are still there.

### #26 60-card legality

- [ ] A new deck shows a red **Not legal** box with "Main deck has 0 cards; Standard needs at least 60."
- [ ] Add 60 Mountain (Add once, then set the count to 60). The box turns green: **Legal**.
- [ ] Add 4 Shock, then set Shock to 5. The box shows "5 copies of Shock; Standard allows 4."
- [ ] Set Shock back to 4 and press **Side** on Shock. The box shows the copy-limit violation again, because main and sideboard count together.
- [ ] Add Lightning Bolt. The box shows "Lightning Bolt is not legal in Standard." Switch the Format dropdown to Modern, and that violation goes away.
- [ ] In Modern, add Chrome Mox. The box shows "Chrome Mox is banned in Modern."
- [ ] Put 16 cards in the sideboard. The box shows the 15-card sideboard limit.
- [ ] Each violation names the card and the rule it breaks.

### #27 Claude builds over MCP

`jac x up` already runs the MCP server over HTTP. Run the `claude mcp add --transport http ...` command it printed, then:

```bash
claude mcp list          # the knowledge-pool-<slug> entry should show as connected
```

In a new Claude Code session:

- [ ] Ask: "Using knowledge-pool, build a Modern mono-red burn deck around Lightning Bolt and Goblin Guide, then validate it." Claude should call `resolve_names`, then `deck_create` or `deck_edit` with a reason on each change, then `deck_validate`, and report legal or the violations.
- [ ] Ask Claude to add "Lightening Bolt" (misspelt) and "Flargle the Unreal". It should come back with Lightning Bolt as a fuzzy candidate and Flargle as unknown, and add neither without asking you.
- [ ] Open the web URL while Claude is connected. The deck Claude made is listed, and its cards match.
- [ ] Create a deck in the web app, then ask Claude to "list my decks". The new deck is in the list.
- [ ] Ask Claude for `deck_get` on its deck. Each change has a reason in `history`.
- [ ] No tool calls a model. Check this by reading the tool code in `mcp_server.jac`: there is no `by llm` anywhere.

To undo the registration afterwards, run `claude mcp remove` with the name from the printed command.

### #25 Go/no-go spike

```bash
jac run --no-serve spike/bench.jac
```

- [ ] `LOAD` is well under 5 minutes (it was 6.7 s).
- [ ] Each `DECK` line has a median under 1 second (it was 224 to 282 ms), and the top suggestions show a score breakdown.
- [ ] `docs/spikes/s02-jac-go-no-go.md` has the numbers, the persistence answer and the go decision.

## Known limits (not bugs)

- Card suggestions in the spike ignore colour identity.
- Decks are single-user. There is no login, and every browser shares one set of decks.
- Each worktree has its own database, so decks made in one worktree do not show in another.
