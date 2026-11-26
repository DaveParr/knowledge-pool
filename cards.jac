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

"""Which catalogue build the `Card` nodes were last refreshed against. One
sits under the guest's root; users never read it."""
node CatalogueRefresh {
    has version: str = "";
}

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
def:protect search_cards(query: str, limit: int = 25) -> CardSearch {
    return search_among(query, limit, None);
}

"""`search_cards` limited, when `only` is not None, to the cards with those oracle ids."""
def search_among(query: str, limit: int, only: list[str] | None) -> CardSearch {
    try {
        found = store.search(query, limit, only);
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

def catalog_info -> CatalogInfo {
    m = store.meta();
    return CatalogInfo(
        mtgjson_version=m["mtgjson_version"] as str,
        mtgjson_date=m["mtgjson_date"] as str,
        card_count=int(m["card_count"])
    );
}

"""The full catalogue record for an oracle id or an exact card name (ignoring
case; a double-faced card also matches by either face). None if nothing matches."""
def find_card(oracle_id_or_name: str) -> JsonObject | None {
    key = oracle_id_or_name.strip();
    if not key {
        return None;
    }
    return store.get_card(key) or store.find_by_name(key);
}

"""Sort names into `exact` matches, `fuzzy` candidates and `unknown` names. Never guesses."""
def resolve_names(names: list[str]) -> JsonObject {
    return store.resolve_names(names);
}

"""The Catalog node under `home`, created on first use."""
def catalog_node(home: Root) -> Catalog {
    found = [home-->[?:Catalog]];
    if found {
        return found[0];
    }
    return (home ++> Catalog()) as Catalog;
}

"""The Catalog node under `home` (the guest's root), open to every user for
reading. The guest calls it before any user call, so no user ever makes one."""
def open_catalog(home: Root) -> Catalog {
    cat = catalog_node(home);
    grant(cat, level=AccessLevel.READ);
    return cat;
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

"""Call `make` with the guest as the acting root, then put the caller back.
Whatever `make` links into the graph is owned by the guest, so the guest can
refresh it and no user can change it. Every user has CONNECT on the guest's
root but no more, so this is the only way a user's call adds to it.

Jac has no public way to act as another root inside a call, so this sets
the context's private `_user_root` field (tests/graph_runner_tests.jac guards it).
With no shared root registered (`jac test`), the caller already acts on
the root everything hangs off, and `make` runs as it is."""
def as_guest(make: Callable[[], object]) -> object {
    shared = Jac.shared_root_id();
    if shared is None {
        return make();
    }
    ctx = Jac.get_context();
    caller = ctx._user_root;
    ctx._user_root = ctx._get_anchor(str(shared));
    try {
        return make();
    } finally {
        ctx._user_root = caller;
    }
}

"""Every Card node for oracle id `oid` under `home`'s Catalog: one, or more
when two processes made the card at once."""
def card_nodes_for(home: Root, oid: str) -> list[Card] {
    found: list[Card] = [];
    for cat in [home-->[?:Catalog]] {
        found.extend([cat-->[?:Card, oracle_id == oid]]);  # jac:ignore[W1051]: the checker cannot resolve a filter field
    }
    return found;
}

"""The Card node for an oracle id under `home`'s Catalog (`home` is the
guest's root, `root.shared`). On first use the guest creates it from the
catalogue, open to every user at CONNECT so their decks can hold it. None if
the id is unknown.

Duplicate cards are not prevented (two processes can both create one), so
with more than one Card node for the id this always picks the lowest id."""
def card_node(home: Root, oid: str) -> Card | None {
    found = card_nodes_for(home, oid);
    if found {
        return min(found, key=jid);
    }
    c = store.get_card(oid);
    if c is None {
        return None;
    }
    return as_guest(lambda () -> object { return new_card(home, oid, c); }) as Card;
}

"""Create the Card node for `oid` from catalogue record `c` under `home`'s
Catalog, open to every user at CONNECT. The guest calls it (see as_guest)."""
def new_card(home: Root, oid: str, c: JsonObject) -> Card {
    card = Card(oracle_id=oid, name=c["name"] as str);
    fill_card(card, c);
    catalog_node(home) ++> card;
    grant(card, level=AccessLevel.CONNECT);
    return card;
}

"""How many Card nodes one `RefreshCards` batch brings up to date."""
glob REFRESH_BATCH: int = 500;

"""Which catalogue build is open: the MTGJSON version and when this file was
built, so a rebuild from the same MTGJSON release still counts as new."""
def catalogue_version -> str {
    m = store.meta();
    return f"{m['mtgjson_version']} @ {m['ingested_at']}";
}

"""The catalogue version the Card nodes under `home` (the guest's root) were
last refreshed against, or "" if they never were."""
def refreshed_version(home: Root) -> str {
    marker = refresh_marker(home);
    return marker.version if marker else "";
}

"""The CatalogueRefresh node under `home`, or None before the first refresh."""
def refresh_marker(home: Root) -> CatalogueRefresh | None {
    found = [home-->[?:CatalogueRefresh]];
    return found[0] if found else None;
}

"""Record under `home` that the Card nodes are now refreshed against `version`."""
def record_refresh(home: Root, version: str) {
    marker = refresh_marker(home);
    if marker {
        marker.version = version;
    } else {
        home ++> CatalogueRefresh(version=version);
    }
}

"""The oracle ids with more than one Card node under `home`'s Catalog, sorted."""
def duplicate_oracle_ids(home: Root) -> list[str] {
    seen: dict[str, int] = {};
    for card in [catalog_node(home)-->[?:Card]] {
        seen[card.oracle_id] = seen.get(card.oracle_id, 0) + 1;
    }
    return sorted([oid for (oid, n) in seen.items() if n > 1]);
}

"""Refresh Card nodes from the catalogue, after `catalog/ingest.py` has
rebuilt it. Reopens the catalogue first (a rebuild replaces the file), then
re-copies every field of `size` cards, in id order, from the `offset`th. A
card the new catalogue no longer has is left as it was, so decks that hold
it keep working. Reports how many cards were updated, then how many were
in the batch (fewer than `size` means the last batch). Safe to re-run.
Only the app runs it, as the guest, at start (`graph_runner.refresh_cards`);
no request reaches it."""
walker RefreshCards {
    has offset: int = 0,
        size: int = REFRESH_BATCH,
        reports: list[int] = [];

    can refresh with Root entry {
        store.reset();
        cards = sorted([catalog_node(here)-->[?:Card]], key=jid);
        in_batch = cards[self.offset:self.offset + self.size];
        updated = 0;
        for card in in_batch {
            c = store.get_card(card.oracle_id);
            if c is not None {
                fill_card(card, c);
                updated += 1;
            }
        }
        report updated;
        report len(in_batch);
    }
}
