"""Ticket 110 test driver. Usage: jac run --no-serve t110.jac <command> [args]."""
import copy;
import json;
import os;
import sys;
import time;
import from uuid { UUID, uuid4 }
import from jaclang { JacRuntime as Jac }
import from jaclang.runtime.context { ExecutionContext }
import from jaclang.runtime.exceptions { WriteConflict }
import from jaclang.server.session { transient_db_error }
import from jaclang.runtime.constants { Constants as Con }
import from cards { Card, Catalog, card_node, catalog_node, RefreshCards }
import from decks { Deck, CreateDeck, EditDeck, GetDeck, ListDecks }
import from deck_io { DeckImport, CreateDeckFromList, resolve_list }
import from legality { format_nodes }
import from walker_errors { WalkerError }

glob APP_DIR: str = os.path.dirname(os.path.abspath(__file__)),
     INJECT: list[int] = [0],
     REPLAYS: list[str] = [];

def um -> any {
    return Jac.get_user_manager(base_path=APP_DIR);
}

def guest_root -> str {
    found = um().get_root_id(Con.GUEST.value);
    if found is None {
        um().ensure_internal_user(Con.GUEST.value, "__no_password__");
        found = um().get_root_id(Con.GUEST.value);
    }
    return str(found);
}

"""Run `f` as the root `root_id` in one transaction; roll back and re-run on a write conflict."""
def run_as(root_id: str, f: any) -> any {
    attempt = 0;
    while True {
        attempt += 1;
        ctx = ExecutionContext(_parent=Jac.get_context());
        ctx.set_user_root(root_id);
        token = Jac.push_request_context(ctx);
        try {
            done = f();
            if INJECT[0] > 0 {
                INJECT[0] -= 1;
                raise WriteConflict(anchor_id=uuid4());
            }
            Jac.commit();
            return done;
        } except Exception as e {
            ctx.mem.abort();
            if attempt >= 8 or not (transient_db_error(e) or isinstance(e, WriteConflict)) {
                raise;
            }
            REPLAYS.append(type(e).__name__);
            time.sleep(0.02 * attempt);
        } finally {
            Jac.reset_request_context(token);
        }
    }
}

def walk_as(root_id: str, w: any) -> any {
    return run_as(root_id, lambda () { return Jac.spawn(Jac.get_context().get_root(), copy.deepcopy(w)); });
}

"""The guest makes the Catalog and Format nodes and opens them to every user for reading."""
def seed_shared() -> None {
    def go() -> None {
        cat = catalog_node(root);
        grant(cat, level=AccessLevel.READ);
        for f in format_nodes(root) {
            grant(f, level=AccessLevel.READ);
        }
    }
    run_as(guest_root(), go);
}

"""The cards a walker will need, read from the walker before it runs."""
def cards_needed(w: any) -> list[str] {
    if isinstance(w, EditDeck) {
        return [str(ch.get("oracle_id", "")) for ch in w.changes];
    }
    if isinstance(w, (DeckImport, CreateDeckFromList)) {
        rl = resolve_list(w.format, w.text);
        if isinstance(rl, WalkerError) {
            return [];
        }
        return [e.oracle_id for e in rl.entries];
    }
    return [];
}

"""Way 1: the runner creates the missing cards as the guest, then runs the walker as the user."""
def walk_precreate(user_root: str, w: any) -> any {
    oids = cards_needed(w);
    if oids {
        run_as(guest_root(), lambda () { return [card_node(root, o) for o in oids]; });
    }
    return walk_as(user_root, w);
}

def owner_name(n: any, names: dict[str, str]) -> str {
    o = str(Jac.owner_of(n));
    return names.get(o, o);
}

"""Every Card node for each oracle id, seen as the system root, with its owner."""
def card_census(names: dict[str, str]) -> list[dict[str, any]] {
    def go() -> list[dict[str, any]] {
        out: list[dict[str, any]] = [];
        for cat in [root-->[?:Catalog]] {
            for c in [cat-->[?:Card]] {
                out.append({"name": c.name, "owner": owner_name(c, names), "id": jid(c), "text": c.text[:40]});
            }
        }
        return out;
    }
    return run_as(guest_root(), go);
}

def show(label: str, v: any) -> None {
    print(label + ": " + json.dumps(v, `default=str));
}

def view(done: any) -> dict[str, any] {
    r = done.reports[0] if done.reports else None;
    if r is None {
        return {"reports": "none"};
    }
    if isinstance(r, WalkerError) {
        return {"error": r.code, "message": r.message};
    }
    v: any = r;
    if hasattr(v, "deck") {
        return {"unresolved": v.unresolved, "cards": [(l.name, l.zone, l.count, l.text[:30]) for l in v.deck.cards]};
    }
    if hasattr(v, "deck_id") {
        return {"deck_id": v.deck_id, "unresolved": v.unresolved};
    }
    if hasattr(v, "cards") {
        return {"id": v.id, "name": v.name, "cards": [(l.name, l.zone, l.count, l.text[:30]) for l in v.cards], "rejected": v.rejected, "legal": v.legal};
    }
    return {"id": jid(v), "name": v.name};
}

def user_root(uid: str) -> str {
    return str(um().ensure_user_root(uid));
}

def names_for(uids: list[str]) -> dict[str, str] {
    names: dict[str, str] = {str(UUID(guest_root())): "GUEST"};
    for u in uids {
        names[str(UUID(user_root(u)))] = u;
    }
    return names;
}

"""Add cards to a new deck as a user. mode is precreate, or inwalker (cards.jac decides by KP110_MODE)."""
def cmd_flow(mode: str, uid: str, oids: list[str]) -> None {
    seed_shared();
    ur = user_root(uid);
    deck = view(walk_as(ur, CreateDeck(name="deck of " + uid, format="standard")));
    show("deck", deck);
    w = EditDeck(deck_id=str(deck["id"]), changes=[{"oracle_id": o, "count": 2, "zone": "main", "reason": "t110"} for o in oids]);
    if os.environ.get("KP110_INJECT") {
        INJECT[0] = int(os.environ["KP110_INJECT"]);
    }
    done = walk_precreate(ur, w) if mode == "precreate" else walk_as(ur, w);
    show("edit", view(done));
    show("replays", REPLAYS);
    show("reread", view(walk_as(ur, GetDeck(deck_id=str(deck["id"])))));
    show("census", card_census(names_for([uid])));
}

with entry {
    Jac.set_shared_root_resolver(guest_root);
    cmd = sys.argv[1] if len(sys.argv) > 1 else "";
    args = sys.argv[2:];
    if cmd == "flow" {
        cmd_flow(args[0], args[1], args[2:]);
    } elif cmd == "census" {
        show("census", card_census(names_for(args)));
    } elif cmd == "decks" {
        ur = user_root(args[0]);
        decks: any = walk_as(ur, ListDecks()).reports[0];
        for d in decks {
            show("deck", view(walk_as(ur, GetDeck(deck_id=jid(d)))));
        }
    } elif cmd == "getdeck" {
        show("deck", view(walk_as(user_root(args[0]), GetDeck(deck_id=args[1]))));
    } elif cmd == "tamper" {
        # a user tries to change a card's text
        def go() -> str {
            c: any = jobj(args[1]);
            if c is None {
                return "jobj -> None";
            }
            c.text = "TAMPERED by " + args[0];
            return "level=" + str(Jac.check_access_level(c.__jac__)) + " in_request=" + c.text;
        }
        try {
            show("tamper", run_as(user_root(args[0]), go));
        } except Exception as e {
            show("tamper raised", type(e).__name__ + ": " + str(e));
        }
    } elif cmd == "guestedit" {
        def go2() -> str {
            c: any = jobj(args[0]);
            c.text = args[1];
            return "level=" + str(Jac.check_access_level(c.__jac__)) + " in_request=" + c.text;
        }
        show("guestedit", run_as(guest_root(), go2));
    } elif cmd == "refresh" {
        show("refresh", walk_as(guest_root(), RefreshCards()).reports);
    } elif cmd == "import" {
        ur = user_root(args[1]);
        seed_shared();
        w2 = CreateDeckFromList(name="imported", format="text", text=args[2], play_format="standard");
        done2 = walk_precreate(ur, w2) if args[0] == "precreate" else walk_as(ur, w2);
        made = view(done2);
        show("import", made);
        if made.get("deck_id") {
            show("reread", view(walk_as(ur, GetDeck(deck_id=str(made["deck_id"])))));
        }
        show("census", card_census(names_for([args[1]])));
    } else {
        print("unknown command");
    }
}
