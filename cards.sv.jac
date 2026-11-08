"""Cards - the card catalogue module. Every caller outside `catalog/` looks
cards up, resolves names and gets graph copies through here.

The full catalogue (about 35,000 oracle cards) stays in SQLite with an FTS5
index; see `catalog/`. Saving every card as a graph node took over 15 minutes,
so a `Card` node is created under the `Catalog` node the first time a deck
uses that card, and reused after that. A `Card` node is a cache of its
catalogue record: after `catalog/ingest.py` rebuilds the catalogue, one
`RefreshCards` brings every existing `Card` node up to date.
"""

import catalog.store as store;

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
    for c in store.search(query, limit) {
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
    m = store.meta();
    return CatalogInfo(
        mtgjson_version=m["mtgjson_version"] as str,
        mtgjson_date=m["mtgjson_date"] as str,
        card_count=int(m["card_count"])
    );
}

"""The full catalogue record for an oracle id or an exact card name (ignoring
case; a double-faced card also matches by either face). None if nothing matches."""
def:pub find_card(oracle_id_or_name: str) -> dict[str, any] | None {
    key = oracle_id_or_name.strip();
    if not key {
        return None;
    }
    return store.get_card(key) or store.find_by_name(key);
}

"""Sort names into `exact` matches, `fuzzy` candidates and `unknown` names. Never guesses."""
def:pub resolve_names(names: list[str]) -> dict[str, any] {
    return store.resolve_names(names);
}

"""The Catalog node under `home`, created on first use."""
def catalog_node(home: Root) -> Catalog {
    found = [home-->[?:Catalog]];
    if found {
        return found[0];
    }
    return (home ++> Catalog())[0] as Catalog;
}

"""Copy every catalogue field of record `c` onto `card`. The one place that
maps a catalogue record to a Card node, so a new field can't be missed by the refresh."""
def fill_card(card: Card, c: dict[str, any]) {
    card.name = c["name"] as str;
    card.mana_cost = c["mana_cost"] as str;
    card.mana_value = c["mana_value"] as float;
    card.colour_identity = c["colour_identity"] as list[str];
    card.types = c["types"] as list[str];
    card.type_line = c["type_line"] as str;
    card.text = c["text"] as str;
    card.legal = c["legal"] as dict[str, str];
    card.oracle_tags = c["oracle_tags"] as list[str];
    card.produced_mana = c["produced_mana"] as list[str];
}

"""The Card node for an oracle id, created from the catalogue on first use. None if the id is unknown."""
def card_node(home: Root, oid: str) -> Card | None {
    cat = catalog_node(home);
    found = [cat-->[?:Card, oracle_id == oid]];
    if found {
        return found[0];
    }
    c = store.get_card(oid);
    if c is None {
        return None;
    }
    card = Card(oracle_id=oid, name=c["name"] as str);
    fill_card(card, c);
    cat ++> card;
    return card;
}

"""Refresh every Card node from the catalogue, after `catalog/ingest.py` has
rebuilt it. Reopens the catalogue first (a rebuild replaces the file), then
re-copies every field. A card the new catalogue no longer has is left as it
was, so decks that hold it keep working. Reports how many cards were updated."""
walker:pub RefreshCards {
    has reports: list[int] = [];

    can refresh with Root entry {
        store.reset();
        updated = 0;
        for card in [catalog_node(here)-->[?:Card]] {
            c = store.get_card(card.oracle_id);
            if c is not None {
                fill_card(card, c);
                updated += 1;
            }
        }
        report updated;
    }
}
