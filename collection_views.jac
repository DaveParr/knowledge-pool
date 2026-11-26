"""What a collection looks like to the web page: the change modes and the view a
collection walker reports. Apart from `collection.jac` (as `zones.jac` is from
`decks.jac`) so the page can import them without pulling the server code into
the client bundle."""

import from decks { ChangeNote }

"""The three ways a change names its count: `MODE_ADD` adds `count` copies,
`MODE_REMOVE` takes `count` away, `MODE_SET` makes it the count."""
glob MODE_ADD: str = "add",
     MODE_REMOVE: str = "remove",
     MODE_SET: str = "set",
     MODES: list[str] = [MODE_ADD, MODE_REMOVE, MODE_SET],
     REFUSED_CHANGE: str = "refused-change",
     NOT_YOUR_COLLECTION: str = "not-your-collection",
     NO_SUCH_USER: str = "no-such-user";

"""One card of a collection with the copies held."""
obj CollectionLine {
    has oracle_id: str,
        name: str,
        count: int;
}

"""A collection: its cards by name with counts, the copies in all, and its
history, newest last."""
obj CollectionView {
    has cards: list[CollectionLine] = [],
        total: int = 0,
        history: list[ChangeNote] = [];
}

"""Another user as the collection views name them: an opaque `handle` that
stands for the user wherever a user is named, and their display name. Never an
email address."""
obj UserSummary {
    has handle: str,
        name: str;
}

"""A walker that acts on the user named by `handle`."""
walker UserAction {
    has handle: str;
}

"""What importing a pasted list into a collection reports: the collection as it
now stands, and the lines or names that resolved to no card (and were not added)."""
obj ImportCollectionResult {
    has collection: CollectionView = CollectionView(),
        unresolved: list[str] = [];
}
