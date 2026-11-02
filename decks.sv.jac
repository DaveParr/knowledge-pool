"""Decks - server side.

Each deck is a `Deck` node hung off `root`, so it persists across restarts in
`.jac/data`. The walkers are `:pub`: this is a local, single-user app, so every
caller shares one graph and nobody has to log in.
"""

import from datetime { datetime, timezone }
import from cards { Card, card_node }

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

"""A deck holds `count` copies of a card."""
edge Holds: Deck --> Card {
    has count: int = 1;
}

"""One line of a deck's card list."""
obj DeckCard {
    has oracle_id: str,
        name: str,
        count: int,
        mana_cost: str,
        type_line: str;
}

"""A deck and its cards, sorted by name."""
obj DeckView {
    has id: str,
        name: str,
        cards: list[DeckCard] = [],
        total: int = 0;
}

def deck_view(deck: Deck) -> DeckView {
    lines: list[DeckCard] = [];
    for c in [deck ->:Holds:->] {
        e = [edge deck ->:Holds:-> c][0];
        lines.append(
            DeckCard(
                oracle_id=c.oracle_id,
                name=c.name,
                count=e.count,
                mana_cost=c.mana_cost,
                type_line=c.type_line
            )
        );
    }
    lines.sort(key=lambda l: DeckCard : l.name);
    return DeckView(
        id=jid(deck),
        name=deck.name,
        cards=lines,
        total=sum([l.count for l in lines])
    );
}

"""The Holds edge from a deck to the card with this oracle id, if any."""
def holds_edge(deck: Deck, oid: str) -> Holds | None {
    for c in [deck ->:Holds:->] {
        if c.oracle_id == oid {
            return [edge deck ->:Holds:-> c][0];
        }
    }
    return None;
}

"""Base for walkers that act on one deck. Reports nothing if the deck id is unknown."""
walker DeckAction {
    has deck_id: str,
        reports: list[DeckView] = [];

    can locate with Root entry {
        try {
            target = jobj(self.deck_id);
        } except ValueError {
            disengage;
        }
        if isinstance(target, Deck) {
            visit [target];
        }
    }
}

"""Report a deck and its cards."""
walker:pub GetDeck(DeckAction) {
    can show with Deck entry {
        report deck_view(here);
    }
}

"""Add copies of a card to a deck (on top of any already there)."""
walker:pub AddCard(DeckAction) {
    has oracle_id: str,
        count: int = 1;

    can add with Deck entry {
        if self.count < 1 {
            disengage;
        }
        existing = holds_edge(here, self.oracle_id);
        if existing is not None {
            existing.count += self.count;
        } else {
            card = card_node(root, self.oracle_id);
            if card is None {
                disengage;
            }
            here +>:Holds(count=self.count):+> card;
        }
        report deck_view(here);
    }
}

"""Set how many copies of a card a deck holds. Zero removes the card."""
walker:pub SetCardCount(DeckAction) {
    has oracle_id: str,
        count: int;

    can set_count with Deck entry {
        if self.count < 0 {
            disengage;
        }
        existing = holds_edge(here, self.oracle_id);
        if existing is None {
            if self.count == 0 {
                report deck_view(here);
                disengage;
            }
            card = card_node(root, self.oracle_id);
            if card is None {
                disengage;
            }
            here +>:Holds(count=self.count):+> card;
        } elif self.count == 0 {
            del existing;
        } else {
            existing.count = self.count;
        }
        report deck_view(here);
    }
}

"""Take a card out of a deck."""
walker:pub RemoveCard(DeckAction) {
    has oracle_id: str;

    can remove with Deck entry {
        existing = holds_edge(here, self.oracle_id);
        if existing is not None {
            del existing;
        }
        report deck_view(here);
    }
}
