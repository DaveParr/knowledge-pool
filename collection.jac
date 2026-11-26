"""Collections: the cards a user has, as a count per oracle card.

A `Collection` hangs off its user's own root, like their decks, and keeps its
change notes as its history. Each count is an `Owns` edge from the collection
to the shared catalogue `Card`, keyed by (card, printing) with the printing
always blank (ADR 0005). Counts change only through `set_count`, the one
writer: it sets an absolute count, treats 0 as removing the card, checks the
reason and logs a `ChangeNote` with no zone. Editing a deck never touches it.
"""

import from datetime { datetime, timezone }
import from cards { Card, card_node }
import from decks { ChangeNote, DeckView }
import from card_lines { missing_cards }
import from walker_errors { WalkerError }
import from deck_io { resolve_list }
import from collection_views { UserAction, UserSummary, CollectionLine, CollectionView, ImportCollectionResult, MODE_ADD, MODE_REMOVE, MODE_SET, MODES, REFUSED_CHANGE, NOT_YOUR_COLLECTION }

"""The reason every card changed by a pasted list is logged with."""
glob REASON_IMPORTED: str = "imported";

"""A user's collection: the node its `Owns` edges and its history hang from."""
node Collection {
    has history: list[ChangeNote] = [];
}

"""The collection holds `count` copies of a card for `printing` (always blank
for now). Change these edges only through `set_count`."""
edge Owns: Collection --> Card {
    has count: int = 1,
        printing: str = "";
}

"""The caller's collection, or None when they have never changed it."""
def find_collection -> Collection | None {
    found = [root-->[?:Collection]];
    return found[0] if found else None;
}

"""The caller's collection, or a new one not yet on their root (`ChangeCollection`
puts it there once a change has been applied)."""
def my_collection -> Collection {
    found = find_collection();
    if found is not None {
        return found;
    }
    return Collection();
}

"""Every (edge, card) pair the collection holds."""
def holdings(coll: Collection) -> list[tuple[Owns, Card]] {
    return [([edge coll ->:Owns:-> c][0], c) for c in [coll ->:Owns:->]];
}

"""The `Owns` edge and card for `oid`, or None when the collection has none."""
def owned(coll: Collection, oid: str) -> tuple[Owns, Card] | None {
    for (e, c) in holdings(coll) {
        if c.oracle_id == oid {
            return (e, c);
        }
    }
    return None;
}

"""Why `count` is not a count a collection can hold, or "" when it is."""
def count_problem(count: int) -> str {
    if not isinstance(count, int) or isinstance(count, bool) or count < 0 {
        return "count must be a whole number, 0 or more.";
    }
    return "";
}

"""The card's name for a message, or `oid` itself when it is not a known card."""
def card_name(oid: str) -> str {
    card = card_node(root.shared, oid);
    return card.name if card is not None else oid;
}

"""How many copies of `oid` the collection holds (every printing)."""
def copies(coll: Collection, oid: str) -> int {
    found = owned(coll, oid);
    return found[0].count if found is not None else 0;
}

"""The one writer. Sets the count of `oid` to the absolute `count` (0 removes
the card) and logs a ChangeNote with `reason`. A change that leaves the count
as it was is applied but not logged. Returns "" when applied, else why it was
refused (and nothing is written)."""
def set_count(coll: Collection, oid: str, count: int, reason: str) -> str {
    if not reason.strip() {
        return "every change needs a reason.";
    }
    problem = count_problem(count);
    if problem {
        return problem;
    }
    found = owned(coll, oid);
    before = found[0].count if found is not None else 0;
    name = "";
    if found is None {
        if count == 0 {
            return "";
        }
        card = card_node(root.shared, oid);
        if card is None {
            return f"{oid} is not a known oracle id.";
        }
        coll +>:Owns(count=count):+> card;
        name = card.name;
    } else {
        (held, card) = found;
        name = card.name;
        if count == 0 {
            del held;
        } else {
            held.count = count;
        }
    }
    if count != before {
        coll.history.append(
            ChangeNote(
                at=datetime.now(timezone.utc).isoformat(),
                oracle_id=oid,
                name=name,
                zone="",
                before=before,
                after=count,
                reason=reason.strip()
            )
        );
    }
    return "";
}

"""Change `oid` by `mode`: add `count` copies, remove `count` copies or set
the count. Works the absolute count out against the current one and passes it
to `set_count`. Returns "" when applied, else why it was refused; removing
more copies than held is refused saying how many are held."""
def change_count(coll: Collection, oid: str, count: int, mode: str, reason: str) -> str {
    if mode not in MODES {
        return f"mode must be one of: {', '.join(MODES)}.";
    }
    problem = count_problem(count);
    if problem {
        return problem;
    }
    have = copies(coll, oid);
    if mode == MODE_REMOVE and count > have {
        return f"you have {have} of {card_name(oid)}, so cannot remove {count}.";
    }
    target = count;
    if mode == MODE_ADD {
        target = have + count;
    } elif mode == MODE_REMOVE {
        target = have - count;
    }
    return set_count(coll, oid, target, reason);
}

"""The collection as a view: every card held, by name, with its count."""
def collection_view(coll: Collection | None) -> CollectionView {
    if coll is None {
        return CollectionView();
    }
    lines = sorted(
        [CollectionLine(oracle_id=c.oracle_id, name=c.name, count=e.count) for (e, c) in holdings(coll)],
        key=lambda (l: CollectionLine) { return l.name; }
    );
    return CollectionView(cards=lines, total=sum([l.count for l in lines]), history=coll.history);
}

"""Report the caller's collection."""
walker:protect GetCollection {
    has reports: list[CollectionView | WalkerError] = [];

    can show with Root entry {
        report collection_view(find_collection());
    }
}

"""Change the count of one card in the caller's collection: `mode` is "add"
(`count` more copies), "remove" (`count` fewer) or "set" (exactly `count`; 0
removes the card), with the `reason`. A `handle` names another user's
collection, which no one but its owner changes: it reports `not-your-collection`
and writes nothing. A refused change (no reason, unknown card,
removing more than held) reports `refused-change` and writes nothing; otherwise
it reports the collection."""
walker:protect ChangeCollection {
    has oracle_id: str,
        count: int,
        mode: str = MODE_ADD,
        reason: str = "",
        handle: str = "",
        reports: list[CollectionView | WalkerError] = [];

    can change with Root entry {
        if self.handle {
            report WalkerError(
                code=NOT_YOUR_COLLECTION,
                message="Only a collection's owner can change it: leave out the handle to change your own."
            );
            disengage;
        }
        coll = my_collection();
        why = change_count(coll, self.oracle_id, self.count, self.mode, self.reason);
        if why {
            report WalkerError(code=REFUSED_CHANGE, message=f"Change refused: {why}");
            disengage;
        }
        if find_collection() is None {
            root ++> coll;
        }
        report collection_view(coll);
    }
}

"""List the other users (never the caller), each by handle and display name.
The deck operations table runs it as a flow (`list_users`): the users are
other roots, which no walker can visit."""
walker:protect ListUsers {
    has reports: list[list[UserSummary] | WalkerError] = [];
}

"""Report another user's collection, by their handle, read-only."""
walker:protect GetOtherCollection(UserAction) {
    has reports: list[CollectionView | WalkerError] = [];

    can show with Root entry {
        report collection_view(find_collection());
    }
}

"""Add a pasted deck list, in any format deck import reads, to the caller's
collection. Zones are ignored and repeats summed; each total is added to the
count held (an import never lowers or removes a count) and logged as "imported".
Lines that resolve to no card are listed in `unresolved` and the rest still go
in. An unknown or import-less list format reports a WalkerError."""
walker:protect ImportCollection {
    has format: str = "mtgdeck1",
        text: str = "",
        reports: list[ImportCollectionResult | WalkerError] = [];

    can do_import with Root entry {
        rl = resolve_list(self.format, self.text);
        if isinstance(rl, WalkerError) {
            report rl;
            disengage;
        }
        totals: dict[str, int] = {};
        for ent in rl.entries {
            totals[ent.oracle_id] = totals.get(ent.oracle_id, 0) + ent.count;
        }
        coll = my_collection();
        unresolved = [*rl.unresolved];
        for (oid, total) in totals.items() {
            why = set_count(coll, oid, copies(coll, oid) + total, REASON_IMPORTED);
            if why {
                unresolved.append(f"{card_name(oid)} ({why})");
            }
        }
        if totals and find_collection() is None {
            root ++> coll;
        }
        report ImportCollectionResult(collection=collection_view(find_collection()), unresolved=unresolved);
    }
}

"""Fill in what the collection of the root this runs on says about each deck
view in `reports`: every card line's `collection_count`. The runner calls it
on the root the walker ran on, so a deck read by another user is always
measured against its owner's collection."""
def stamp_collection(reports: list[any]) -> None {
    coll = find_collection();
    for item in reports {
        if isinstance(item, DeckView) {
            for line in item.cards {
                line.collection_count = copies(coll, line.oracle_id) if coll is not None else 0;
            }
            item.missing = missing_cards(item.cards);
            item.sleeveable = len(item.missing) == 0;
        }
    }
}
