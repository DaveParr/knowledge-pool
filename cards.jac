"""Cards - the card catalogue module. Every caller outside `catalog/` looks
cards up, resolves names and gets graph copies through here.

The full catalogue (about 35,000 oracle cards) stays in SQLite with an FTS5
index; see `catalog/`. Saving every card as a graph node took over 15 minutes,
so a `Card` node is created under the `Catalog` node the first time a deck
uses that card, and reused after that. A `Card` node is a cache of its
catalogue record: after `catalog/ingest.py` rebuilds the catalogue, one
`RefreshCards` brings every existing `Card` node up to date.
"""

import sqlite3;
import catalog.store as store;
import from jaclang { JacRuntime as Jac }
import from card_lines { CardFace }
import from json_object { JsonObject }

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
        produced_mana: list[str] = [],
        power: str = "",
        toughness: str = "",
        loyalty: str = "",
        defense: str = "",
        keywords: list[str] = [],
        faces: list[CardFace] = [],
        leadership: dict[str, bool] = {},
        game_changer: bool = False;
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

"""Search results, or why the search failed. `error` is "" when it worked."""
obj CardSearch {
    has hits: list[CardHit] = [],
        error: str = "";
}

"""Search card names, type lines and rules text. Every word must match.
A missing or out-of-date catalogue comes back as `error`, not an exception."""
def:pub search_cards(query: str, limit: int = 25) -> CardSearch {
    try {
        found = store.search(query, limit);
    } except (sqlite3.Error, FileNotFoundError) as e {
        return CardSearch(error=f"Card search failed: {e}");
    }
    hits: list[CardHit] = [];
    for c in found {
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
    return CardSearch(hits=hits);
}

"""Raise if the catalogue was built by older code; the error names the ingest
command. Run at startup so the app refuses to serve a stale catalogue."""
def check_catalogue {
    store.check_current();
}

def:pub catalog_info -> CatalogInfo {
    m = store.meta();
    return CatalogInfo(
        mtgjson_version=m["mtgjson_version"] as str,
        mtgjson_date=m["mtgjson_date"] as str,
        card_count=int(m["card_count"])
    );
}

"""The full catalogue record for an oracle id or an exact card name (ignoring
case; a double-faced card also matches by either face). None if nothing matches."""
def:pub find_card(oracle_id_or_name: str) -> JsonObject | None {
    key = oracle_id_or_name.strip();
    if not key {
        return None;
    }
    return store.get_card(key) or store.find_by_name(key);
}

"""Sort names into `exact` matches, `fuzzy` candidates and `unknown` names. Never guesses."""
def:pub resolve_names(names: list[str]) -> JsonObject {
    return store.resolve_names(names);
}

"""The root that holds the shared cards and formats: the guest's root, which
the runner registers as Jac's shared root. With none registered (a walker
test), the current root."""
def shared_root -> Root {
    return root.shared;
}

"""Run `work` with `home`, the shared root, as the acting root, so what it
saves is owned by the guest, not the caller. Switches back in a `finally`.
Relies on Jac's private `_user_root` context field; `runner_tests.jac` fails
if Jac renames it."""
def as_owner_of(home: Root, work: Callable[[], object]) -> object {
    ctx = Jac.get_context();
    acting = ctx._user_root;
    ctx._user_root = home.__jac__;
    try {
        return work();
    } finally {
        ctx._user_root = acting;
    }
}

"""The Catalog node under `home`, created on first use (by `home`'s owner)."""
def catalog_node(home: Root) -> Catalog {
    found = [home-->[?:Catalog]];
    if found {
        return found[0];
    }
    return as_owner_of(home, lambda -> Catalog { return (home ++> Catalog()) as Catalog; }) as Catalog;
}

"""Copy every catalogue field of record `c` onto `card`. The one place that
maps a catalogue record to a Card node, so a new field can't be missed by the refresh."""
def fill_card(card: Card, c: JsonObject) {
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
    card.power = c["power"] as str;
    card.toughness = c["toughness"] as str;
    card.loyalty = c["loyalty"] as str;
    card.defense = c["defense"] as str;
    card.keywords = c["keywords"] as list[str];
    faces = c["faces"] as list[dict[str, str]];
    card.faces = [card_face(f) for f in faces];
    card.leadership = c["leadership"] as dict[str, bool];
    card.game_changer = c["game_changer"] as bool;
}

"""A catalogue face record as a CardFace."""
def card_face(f: dict[str, str]) -> CardFace {
    return CardFace(
        name=f["name"],
        mana_cost=f["mana_cost"],
        type_line=f["type_line"],
        text=f["text"],
        power=f["power"],
        toughness=f["toughness"],
        loyalty=f["loyalty"],
        defense=f["defense"]
    );
}

"""The Card node for an oracle id, from the shared Catalog, created from the
catalogue on first use. None if the id is unknown. A new card is created and
linked by the guest and opened at CONNECT: every user's deck can hold it, and
no user can change it."""
def card_node(oid: str) -> Card | None {
    home = shared_root();
    cat = catalog_node(home);
    found = [cat-->[?:Card, oracle_id == oid]];  # jac:ignore[W1051]: the checker cannot resolve a filter field
    if found {
        return found[0];
    }
    c = store.get_card(oid);
    if c is None {
        return None;
    }
    card = Card(oracle_id=oid, name=c["name"] as str);
    fill_card(card, c);
    as_owner_of(home, lambda { cat ++> card; grant(card, level=AccessLevel.CONNECT); });
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
        for card in [catalog_node(shared_root())-->[?:Card]] {
            c = store.get_card(card.oracle_id);
            if c is not None {
                fill_card(card, c);
                updated += 1;
            }
        }
        report updated;
    }
}
