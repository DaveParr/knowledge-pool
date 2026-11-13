import from jaclang { JacRuntime as Jac }
import from uuid { UUID }

node Catalog { has tag: str; has version: str = "v1"; }
node Card { has oracle_id: str; has name: str; }
node Format { has name: str; }
node Deck { has name: str; }
edge Holds: Deck --> Card { has count: int = 1; has zone: str = "main"; }

def lvl(name: str) -> AccessLevel {
    r: any = AccessLevel[name];
    return r;
}

def node_of(node_id: str) -> any {
    return jobj(node_id);
}

def seed(tag: str, cat_level: str, card_level: str, fmt_level: str) -> dict[str, any] {
    cat = root.shared ++> Catalog(tag=tag);
    if cat_level != "none" { grant(cat, level=lvl(cat_level)); }
    card = cat ++> Card(oracle_id=tag + "-bolt", name="Lightning Bolt");
    if card_level != "none" { grant(card, level=lvl(card_level)); }
    fmt = cat ++> Format(name="commander");
    if fmt_level != "none" { grant(fmt, level=lvl(fmt_level)); }
    return {
        "me": jid(root), "shared": jid(root.shared), "cat": jid(cat),
        "card": jid(card), "fmt": jid(fmt)
    };
}

def:protect seed_as_user(tag: str, cat_level: str, card_level: str, fmt_level: str) -> dict[str, any] {
    return seed(tag, cat_level, card_level, fmt_level);
}

def:pub seed_as_guest(tag: str, cat_level: str, card_level: str, fmt_level: str) -> dict[str, any] {
    return seed(tag, cat_level, card_level, fmt_level);
}

def find_cat(tag: str) -> (Catalog | None) {
    for c in [root.shared --> [?:Catalog]] {
        if c.tag == tag { return c; }
    }
    return None;
}

def:protect whoami() -> dict[str, any] {
    return {"root": jid(root), "shared": jid(root.shared),
            "shared_level": str(Jac.check_access_level(root.shared.__jac__))};
}

def:protect look(tag: str) -> dict[str, any] {
    out: dict[str, any] = {"cats_visible": [c.tag for c in [root.shared --> [?:Catalog]]]};
    cat = find_cat(tag);
    if cat is None { out["cat"] = None; return out; }
    out["cat_level"] = str(Jac.check_access_level(cat.__jac__));
    out["cards"] = [{"id": jid(c), "name": c.name, "level": str(Jac.check_access_level(c.__jac__))} for c in [cat --> [?:Card]]];
    out["formats"] = [{"id": jid(f), "name": f.name, "level": str(Jac.check_access_level(f.__jac__))} for f in [cat --> [?:Format]]];
    return out;
}

def:protect make_deck(tag: str, name: str, count: int) -> dict[str, any] {
    cat = find_cat(tag);
    if cat is None { return {"error": "no catalog visible"}; }
    cards = [cat --> [?:Card]];
    if not cards { return {"error": "no card visible"}; }
    card = cards[0];
    deck = root ++> Deck(name=name);
    deck +>:Holds(count=count, zone="main"):+> card;
    edges = [edge deck ->:Holds:->];
    return {"deck": jid(deck), "root": jid(root), "card": jid(card),
            "edges": [jid(e) for e in edges]};
}

def:protect my_deck(deck_id: str) -> dict[str, any] {
    deck = node_of(deck_id);
    if deck is None { return {"error": "no-such-deck"}; }
    return {
        "name": deck.name,
        "level": str(Jac.check_access_level(deck.__jac__)),
        "cards": [c.name for c in [deck ->:Holds:->]],
        "holds": [{"id": jid(e), "count": e.count, "zone": e.zone} for e in [edge deck ->:Holds:->]]
    };
}

def attempt(label: str, out: dict[str, any], f: any) {
    try { out[label] = f(); } except Exception as e { out[label] = "EXC " + type(e).__name__ + ": " + str(e); }
}

def describe(xs: any) -> list[str] {
    return [type(x).__name__ + ":" + jid(x) for x in xs];
}

"""Everything a user can see around one shared node, by id."""
def:protect probe(node_id: str) -> dict[str, any] {
    out: dict[str, any] = {};
    n = node_of(node_id);
    if n is None { return {"resolved": None}; }
    out["type"] = type(n).__name__;
    out["level"] = str(Jac.check_access_level(n.__jac__));
    attempt("in_nodes", out, lambda () { return describe([n <--]); });
    attempt("out_nodes", out, lambda () { return describe([n -->]); });
    attempt("both_nodes", out, lambda () { return describe([n <-->]); });
    attempt("in_holds_nodes", out, lambda () { return describe([n <-:Holds:<-]); });
    attempt("in_edges", out, lambda () { return describe([edge n <--]); });
    attempt("in_holds_edges", out, lambda () { return describe([edge n <-:Holds:<-]); });
    attempt("both_edges", out, lambda () { return describe([edge n <-->]); });
    attempt("len_in_nodes", out, lambda () { return len([n <--]); });
    attempt("len_in_edges", out, lambda () { return len([edge n <--]); });
    attempt("in_decks", out, lambda () { return [d.name for d in [n <-- [?:Deck]]]; });
    attempt("anchor_edges", out, lambda () { return [str(e) for e in n.__jac__.edges]; });
    attempt("anchor_dict", out, lambda () { return [k for k in vars(n.__jac__).keys()]; });
    attempt("printgraph", out, lambda () { return printgraph(n); });
    return out;
}

"""Does an id resolve for the caller, and what can they read on it."""
def:protect resolve(ids: list[str]) -> dict[str, any] {
    out: dict[str, any] = {};
    for i in ids {
        try {
            n = node_of(i);
            if n is None { out[i] = None; }
            else { out[i] = {"type": type(n).__name__, "fields": str(vars(n)), "level": str(Jac.check_access_level(n.__jac__))}; }
        } except Exception as e { out[i] = "EXC " + type(e).__name__ + ": " + str(e); }
    }
    out["allroots"] = [jid(r) for r in allroots()];
    out["allroots_decks"] = [d.name for r in allroots() for d in [r --> [?:Deck]]];
    return out;
}

def:protect rename_node(node_id: str, name: str) -> dict[str, any] {
    n = node_of(node_id);
    if n is None { return {"resolved": None}; }
    before = n.name;
    n.name = name;
    return {"before": before, "after_in_request": n.name};
}

def:pub rename_node_pub(node_id: str, name: str) -> dict[str, any] {
    n = node_of(node_id);
    if n is None { return {"resolved": None}; }
    before = n.name;
    n.name = name;
    return {"before": before, "after_in_request": n.name, "root": jid(root)};
}

def:protect delete_node(node_id: str) -> dict[str, any] {
    n = node_of(node_id);
    if n is None { return {"resolved": None}; }
    del n;
    return {"deleted_in_request": True};
}

def:protect delete_in_edges(node_id: str) -> dict[str, any] {
    n = node_of(node_id);
    if n is None { return {"resolved": None}; }
    k = len([edge n <--]);
    del [edge n <--];
    return {"edges_seen": k};
}

def:protect attach_junk(node_id: str) -> dict[str, any] {
    n: (Card | None) = jobj(node_id) as Card;
    if n is None { return {"resolved": None}; }
    j = n ++> Format(name="junk");
    return {"junk": jid(j), "out_now": describe([n -->])};
}

def:protect share(deck_id: str, target_root: str, with_edges: bool, with_all: bool) -> dict[str, any] {
    deck = node_of(deck_id);
    if deck is None { return {"error": "no-such-deck"}; }
    if with_all {
        grant(deck, level=AccessLevel.READ);
    } else {
        Jac.allow_root(deck, UUID(target_root), AccessLevel.READ);  # jac:ignore[E1053]
    }
    k = 0;
    if with_edges {
        for e in [edge deck ->:Holds:->] {
            Jac.allow_root(e, UUID(target_root), AccessLevel.READ);  # jac:ignore[E1053]
            k += 1;
        }
    }
    return {"shared": True, "edges_granted": k};
}

def:protect unshare(deck_id: str, target_root: str) -> dict[str, any] {
    deck = node_of(deck_id);
    if deck is None { return {"error": "no-such-deck"}; }
    Jac.disallow_root(deck, UUID(target_root));  # jac:ignore[E1053]
    revoke(deck);
    for e in [edge deck ->:Holds:->] {
        Jac.disallow_root(e, UUID(target_root));  # jac:ignore[E1053]
    }
    return {"unshared": True};
}

walker:protect ReadDeck {
    can go with Deck entry {
        report {"name": here.name, "cards": [c.name for c in [here ->:Holds:->]],
                "holds": [e.count for e in [edge here ->:Holds:->]]};
    }
}

walker:protect BackFromCard {
    can start with Card entry {
        report {"at": "card", "name": here.name};
        visit [<--];
    }
    can deck with Deck entry { report {"at": "deck", "name": here.name, "id": jid(here)}; }
    can cat with Catalog entry { report {"at": "catalog", "tag": here.tag}; }
}

walker:protect BackEdgesFromCard {
    can start with Card entry {
        report {"at": "card"};
        visit [edge <--];
    }
    can hold with Holds entry { report {"at": "holds", "count": here.count, "id": jid(here)}; }
    can deck with Deck entry { report {"at": "deck", "name": here.name}; }
}

# ---- round 2 ----
node OpenCatalog(Catalog) {
    def __jac_access__ -> AccessLevel { return AccessLevel.READ; }
}
node OpenCard(Card) {
    def __jac_access__ -> AccessLevel { return AccessLevel.CONNECT; }
}
node OpenFormat(Format) {
    def __jac_access__ -> AccessLevel { return AccessLevel.READ; }
}

def:pub seed_open(tag: str) -> dict[str, any] {
    cat = root.shared ++> OpenCatalog(tag=tag);
    card = cat ++> OpenCard(oracle_id=tag + "-bolt", name="Lightning Bolt");
    fmt = cat ++> OpenFormat(name="commander");
    return {"me": jid(root), "cat": jid(cat), "card": jid(card), "fmt": jid(fmt)};
}

def:protect edit_own(deck_id: str, count: int) -> dict[str, any] {
    deck = node_of(deck_id);
    if deck is None { return {"error": "no-such-deck"}; }
    for e in [edge deck ->:Holds:->] { e.count = count; }
    return {"holds": [e.count for e in [edge deck ->:Holds:->]]};
}

def:protect remove_card(deck_id: str) -> dict[str, any] {
    deck = node_of(deck_id);
    if deck is None { return {"error": "no-such-deck"}; }
    del [edge deck ->:Holds:->];
    return {"holds_in_request": len([edge deck ->:Holds:->])};
}

def:protect get_card(node_id: str) -> any {
    return node_of(node_id);
}

walker:protect ReportCard {
    can go with Card entry { report here; }
}

def:protect remove_card2(tag: str, deck_name: str, how: str) -> dict[str, any] {
    decks = [root --> [?:Deck]];
    for deck in decks {
        if deck.name == deck_name {
            before = len([edge deck ->:Holds:->]);
            if how == "query" {
                del [edge deck ->:Holds:->];
            } elif how == "loop" {
                for e in [edge deck ->:Holds:->] { del e; }
            } elif how == "disconnect" {
                for c in [deck ->:Holds:->] { deck del --> c; }
            }
            return {"before": before, "after_in_request": len([edge deck ->:Holds:->])};
        }
    }
    return {"error": "no-such-deck"};
}

def:protect delete_in_edges_loop(node_id: str) -> dict[str, any] {
    n = node_of(node_id);
    if n is None { return {"resolved": None}; }
    seen = [jid(e) for e in [edge n <-:Holds:<-]];
    for e in [edge n <-:Holds:<-] { del e; }
    return {"edges_seen": seen, "after_in_request": len([edge n <-:Holds:<-])};
}
