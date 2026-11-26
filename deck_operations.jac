"""Deck operations: the one table of what the app can do with decks, and the one
call, `perform`, that both edges (the front door for the web page, the MCP tools
for the connector) make to do it.

Each entry of `OPERATIONS` names a walker (every one the edges call, including
`GetFormatRules`, which reads the shared rules and takes no deck) and says how
it runs:

- `OWN`: on the caller's own root (`run_walker`). A walker that acts on one deck
  answers `not-your-deck` for another user's deck and `no-such-deck` for an id
  that names no deck, so every change is the owner's alone.
- `OWNER`: on the root of the deck's owner, for a read-only walker (`run_read`):
  any user may read any deck (CONTEXT.md, "Reading another user's deck"). The
  walker must change nothing; this table is the one list of the ones `perform`
  runs so (`copy_deck` also reads `CopySource` this way, listed for
  completeness).
- `FLOW`: a runner flow across users' roots that no single walker can make,
  named by the entry's `across` (listing other users' decks, copying a deck).

An entry also says whether the web page may call the walker (`page`): the front
door's table of page-callable walkers is `page_walkers()`, derived from here.
Every page-callable walker must still be `:protect` (ADR-0004).

Adding a deck action means writing the walker and adding one entry here; a
page-callable one must also be imported in `main.jac`, which a test checks.
"""

import from jaclang.runtime.constructs { WalkerArchetype }
import from graph_runner { run_walker, run_read, copy_deck, list_other_decks }
import from decks { DeckAction, CreateDeck, ListDecks, ListOtherDecks, CopyOtherDeck, CopySource, GetDeck, EditDeck }
import from deck_io { DeckExport, DeckImport, CreateDeckFromList }
import from legality { GetFormatRules }
import from collection { GetCollection, ChangeCollection, ImportCollection }

glob OWN: str = "own",
     OWNER: str = "owner",
     FLOW: str = "flow";

"""How a flow runs `w` for `caller`: the finished walker, its one report the
result or a walker error."""
def list_others_flow(caller: str | None, w: WalkerArchetype) -> WalkerArchetype {
    w.reports = [list_other_decks(caller)];
    return w;
}

"""Copy the deck the walker names, whoever owns it, into the caller's own decks."""
def copy_flow(caller: str | None, w: WalkerArchetype) -> WalkerArchetype {
    return copy_deck(caller, (w as DeckAction).deck_id);
}

"""One deck operation: the walker class `kind` that does it, how it `runs`
(`OWN`, `OWNER` or `FLOW`), the `across` function that runs it when it is a
`FLOW`, and whether the web `page` may call it."""
obj DeckOperation {
    has kind: type,
        runs: str,
        page: bool = False,
        across: Callable[[str | None, WalkerArchetype], WalkerArchetype] | None = None;
}

glob OPERATION_LIST: list[DeckOperation] = [
    DeckOperation(kind=CreateDeck, runs=OWN, page=True),
    DeckOperation(kind=ListDecks, runs=OWN, page=True),
    DeckOperation(kind=ListOtherDecks, runs=FLOW, page=True, across=list_others_flow),
    DeckOperation(kind=CopyOtherDeck, runs=FLOW, page=True, across=copy_flow),
    DeckOperation(kind=GetDeck, runs=OWNER, page=True),
    DeckOperation(kind=EditDeck, runs=OWN, page=True),
    DeckOperation(kind=DeckExport, runs=OWNER, page=True),
    DeckOperation(kind=DeckImport, runs=OWN, page=True),
    DeckOperation(kind=CreateDeckFromList, runs=OWN, page=True),
    DeckOperation(kind=GetCollection, runs=OWN, page=True),
    DeckOperation(kind=ChangeCollection, runs=OWN, page=True),
    DeckOperation(kind=ImportCollection, runs=OWN, page=True),
    DeckOperation(kind=CopySource, runs=OWNER),
    DeckOperation(kind=GetFormatRules, runs=OWN)
];

"""The table: each operation by its walker's name."""
glob OPERATIONS: dict[str, DeckOperation] = {op.kind.__name__: op for op in OPERATION_LIST};

"""The walkers the web page may call, by name: the front door's table, derived."""
def page_walkers -> dict[str, type] {
    return {name: op.kind for (name, op) in OPERATIONS.items() if op.page};
}

"""Run the operation `w` (a walker with its fields set) as `caller`, the way its
table entry says, and return the finished walker: its first report is the result,
or a walker error. It never raises `CallFailed`: a call the runner could not
finish reports `try-again` or `internal-error`. No caller is a refusal
(`PermissionError`)."""
def perform(caller: str | None, w: WalkerArchetype) -> WalkerArchetype {
    op = OPERATIONS.get(type(w).__name__);
    if op is None {
        raise TypeError(f"{type(w).__name__} is not a deck operation: add it to OPERATIONS in deck_operations.jac.");
    }
    if op.runs == FLOW {
        return op.across(caller, w) as WalkerArchetype;
    }
    if op.runs == OWNER {
        return run_read(caller, (w as DeckAction).deck_id, w);
    }
    return run_walker(caller, w);
}
