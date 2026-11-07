"""Cards - search the catalogue and keep the cards that decks use.

The full catalogue (about 35,000 oracle cards) stays in SQLite with an FTS5
index; see `catalog/`. Saving every card as a graph node took over 15 minutes,
so a `Card` node is created under the `Catalog` node the first time a deck
uses that card, and reused after that.
"""

import from catalog.store { search as catalog_search, get_card as catalog_get, meta as catalog_meta }

node Catalog {}

node Card {
    has oracle_id: str,
        name: str,
        mana_cost: str = "",
        mana_value: float = 0.0,
        colour_identity: list[str] = [],
        types: list[str] = [],
        type_line: str = "",
        text: str = "",
        legal: dict[str, str] = {},
        oracle_tags: list[str] = [],
        produced_mana: list[str] = [];
}

"""One search result."""
obj CardHit {
    has oracle_id: str,
        name: str,
        mana_cost: str,
        type_line: str,
        text: str;
}

"""Which MTGJSON build the catalogue came from."""
obj CatalogInfo {
    has mtgjson_version: str,
        mtgjson_date: str,
        card_count: int;
}

"""Search card names, type lines and rules text. Every word must match."""
def:pub search_cards(query: str, limit: int = 25) -> list[CardHit] {
    hits: list[CardHit] = [];
    for c in catalog_search(query, limit) {
        hits.append(
            CardHit(
                oracle_id=c["oracle_id"] as str,
                name=c["name"] as str,
                mana_cost=c["mana_cost"] as str,
                type_line=c["type_line"] as str,
                text=c["text"] as str
            )
        );
    }
    return hits;
}

def:pub catalog_info() -> CatalogInfo {
    m = catalog_meta();
    return CatalogInfo(
        mtgjson_version=m["mtgjson_version"] as str,
        mtgjson_date=m["mtgjson_date"] as str,
        card_count=int(m["card_count"])
    );
}

"""The Catalog node under `home`, created on first use."""
def catalog_node(home: Root) -> Catalog {
    found = [home-->[?:Catalog]];
    if found {
        return found[0];
    }
    return (home ++> Catalog())[0] as Catalog;
}

"""The Card node for an oracle id, created from SQLite on first use. None if the id is unknown."""
def card_node(home: Root, oid: str) -> Card | None {
    cat = catalog_node(home);
    found = [cat-->[?:Card, oracle_id == oid]];
    if found {
        return found[0];
    }
    c = catalog_get(oid);
    if c is None {
        return None;
    }
    card = Card(
        oracle_id=c["oracle_id"] as str,
        name=c["name"] as str,
        mana_cost=c["mana_cost"] as str,
        mana_value=c["mana_value"] as float,
        colour_identity=c["colour_identity"] as list[str],
        types=c["types"] as list[str],
        type_line=c["type_line"] as str,
        text=c["text"] as str,
        legal=c["legal"] as dict[str, str],
        oracle_tags=c["oracle_tags"] as list[str],
        produced_mana=c["produced_mana"] as list[str]
    );
    cat ++> card;
    return card;
}

"""Re-read every Card node's `oracle_tags` from SQLite. `card_node()` never
refreshes a Card once it's materialized, so this is the explicit step an
operator runs after `catalog/ingest.py` rebuilds the catalogue."""
walker:pub SyncCardTags {
    has reports: list[int] = [];

    can sync with Root entry {
        cat = catalog_node(here);
        updated = 0;
        for card in [cat-->[?:Card]] {
            c = catalog_get(card.oracle_id);
            if c is not None {
                card.oracle_tags = c["oracle_tags"] as list[str];
                updated += 1;
            }
        }
        report updated;
    }
}
