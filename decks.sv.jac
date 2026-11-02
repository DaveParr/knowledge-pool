"""Decks - server side.

Each deck is a `Deck` node hung off `root`, so it persists across restarts in
`.jac/data`. The walkers are `:pub`: this is a local, single-user app, so every
caller shares one graph and nobody has to log in.
"""

import from datetime { datetime, timezone }

node Deck {
    has name: str,
        created_at: str = "";
}

"""Create a deck and report it. A blank name creates nothing and reports nothing."""
walker:pub CreateDeck {
    has name: str,
        reports: list[Deck] = [];

    can create with Root entry {
        name = self.name.strip();
        if not name {
            disengage;
        }
        deck = Deck(
            name=name,
            created_at=datetime.now(timezone.utc).isoformat()
        );
        here ++> deck;
        report deck;
    }
}

"""Report every deck, oldest first."""
walker:pub ListDecks {
    has reports: list[list[Deck]] = [];

    can collect with Root entry {
        decks = sorted([here-->[?:Deck]], key=lambda d: Deck : d.created_at);
        report decks;
    }
}
