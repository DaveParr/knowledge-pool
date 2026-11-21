"""Deck operations: the one table of what the app can do with decks, and the one
call, `perform`, that both edges (the front door for the web page, the MCP tools
for the connector) make to do it.

Each entry of `OPERATIONS` names a walker and says how it runs:

- `OWN`: on the caller's own root (`run_walker`). A walker that acts on one deck
  answers `not-your-deck` for another user's deck and `no-such-deck` for an id
  that names no deck, so every change is the owner's alone.
- `OWNER`: on the root of the deck's owner, for a read-only walker (`run_read`):
  any user may read any deck (CONTEXT.md, "Reading another user's deck"). The
  walker must change nothing; this table is the one list of the ones that run so.
- `FLOW`: a runner flow across users' roots that no single walker can make,
  named by the entry's `across` (listing other users' decks, copying a deck).

An entry also says whether the web page may call the walker (`page`): the front
door's table of page-callable walkers is `page_walkers()`, derived from here.
Every page-callable walker must still be `:protect` (ADR-0004).

Adding a deck action means writing the walker and adding one entry here.
"""

import from jaclang.runtime.constructs { WalkerArchetype }
import from decks { DeckAction }
import from graph_runner { run_walker, run_read, copy_deck, list_other_decks, failed_walker, CallFailed }
import from decks { CreateDeck, ListDecks, ListOtherDecks, CopyOtherDeck, CopySource, GetDeck, SetDeckFormat, RenameDeck, AddCard, SetCardCount, RemoveCard, EditDeck }
import from deck_io { DeckExport, DeckImport, CreateDeckFromList }
import from legality { GetFormatRules }

glob OWN: str = "own",
     OWNER: str = "owner",
     FLOW: str = "flow";

"""How a flow runs `w` for `caller`: the finished walker, its one report the result
or a walker error."""
def list_others_flow(caller: str | None, w: WalkerArchetype) -> WalkerArchetype {
    try {
        w.reports = [list_other_decks(caller)];
    } except CallFailed as failed {
        return failed_walker(w, failed);
    }
    return w;
}

"""Copy the deck the walker names, whoever owns it, into the caller's own decks."""
def copy_flow(caller: str | None, w: WalkerArchetype) -> WalkerArchetype {
    return copy_deck(caller, (w as DeckAction).deck_id);
}

"""One deck operation: the walker class `kind` that does it, how it `runs` (`OWN`, `OWNER` or
`FLOW`), the `across` function that runs it when it is a `FLOW`, and whether the web `page` may call it."""
obj DeckOperation {
    has kind: type,
        runs: str,
        page: bool = False,
        across: Callable[[str | None, WalkerArchetype], WalkerArchetype] | None = None;
}

glob OPERATIONS: dict[str, DeckOperation] = {
    "CreateDeck": DeckOperation(kind=CreateDeck, runs=OWN, page=True),
    "ListDecks": DeckOperation(kind=ListDecks, runs=OWN, page=True),
    "ListOtherDecks": DeckOperation(kind=ListOtherDecks, runs=FLOW, page=True, across=list_others_flow),
    "CopyOtherDeck": DeckOperation(kind=CopyOtherDeck, runs=FLOW, page=True, across=copy_flow),
    "GetDeck": DeckOperation(kind=GetDeck, runs=OWNER, page=True),
    "SetDeckFormat": DeckOperation(kind=SetDeckFormat, runs=OWN, page=True),
    "RenameDeck": DeckOperation(kind=RenameDeck, runs=OWN, page=True),
    "AddCard": DeckOperation(kind=AddCard, runs=OWN, page=True),
    "SetCardCount": DeckOperation(kind=SetCardCount, runs=OWN, page=True),
    "RemoveCard": DeckOperation(kind=RemoveCard, runs=OWN, page=True),
    "DeckExport": DeckOperation(kind=DeckExport, runs=OWNER, page=True),
    "DeckImport": DeckOperation(kind=DeckImport, runs=OWN, page=True),
    "CreateDeckFromList": DeckOperation(kind=CreateDeckFromList, runs=OWN, page=True),
    "EditDeck": DeckOperation(kind=EditDeck, runs=OWN),
    "CopySource": DeckOperation(kind=CopySource, runs=OWNER),
    "GetFormatRules": DeckOperation(kind=GetFormatRules, runs=OWN)
};

"""The walkers the web page may call, by name: the front door's table, derived."""
def page_walkers -> dict[str, type] {
    return {name: op.kind for (name, op) in OPERATIONS.items() if op.page};
}

"""Run the operation `w` (a walker with its fields set) as `caller`, the way its
table entry says, and return the finished walker: its first report is the result,
or a walker error. A call the runner could not finish reports `try-again` or
`internal-error`. No caller is a refusal (`PermissionError`)."""
def perform(caller: str | None, w: WalkerArchetype) -> WalkerArchetype {
    op = OPERATIONS.get(type(w).__name__);
    if op is None or op.kind is not type(w) {
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
