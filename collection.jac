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
import from decks { ChangeNote }
import from walker_errors { WalkerError }
import from collection_views { CollectionLine, CollectionView, MODE_ADD, MODE_REMOVE, MODE_SET, MODES, REFUSED_CHANGE }

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

"""The caller's collection, made on first use."""
def my_collection -> Collection {
    found = find_collection();
    if found is not None {
        return found;
    }
    made = Collection();
    root ++> made;
    return made;
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
    target = count if mode == MODE_SET else (have + count if mode == MODE_ADD else have - count);
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
removes the card), with the `reason`. A refused change (no reason, unknown card,
removing more than held) reports `refused-change` and writes nothing; otherwise
it reports the collection."""
walker:protect ChangeCollection {
    has oracle_id: str,
        count: int,
        mode: str = MODE_ADD,
        reason: str = "",
        reports: list[CollectionView | WalkerError] = [];

    can change with Root entry {
        coll = my_collection();
        why = change_count(coll, self.oracle_id, self.count, self.mode, self.reason);
        if why {
            report WalkerError(code=REFUSED_CHANGE, message=f"Change refused: {why}");
            disengage;
        }
        report collection_view(coll);
    }
}
