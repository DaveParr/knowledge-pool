"""Run as a chosen identity in process, the way shared_graph.jac run_walker does."""
import os;
import sys;
import from jaclang { JacRuntime as Jac }
import from jaclang.runtime.context { ExecutionContext }
import from jaclang.runtime.constants { Constants as Con }
import from main { Card, Deck, Holds, Catalog, Format }

def as_root(root_id: str, node_id: str, new_name: str) -> str {
    ctx = ExecutionContext(_parent=Jac.get_context());
    ctx.set_user_root(root_id);
    token = Jac.push_request_context(ctx);
    try {
        n: any = jobj(node_id);
        if n is None { return "jobj -> None"; }
        before = n.name;
        n.name = new_name;
        Jac.commit();
        return "before=" + str(before) + " after_in_request=" + str(n.name) + " shared=" + jid(root.shared) + " root=" + jid(root);
    } finally {
        Jac.reset_request_context(token);
    }
}

with entry {
    um = Jac.get_user_manager(base_path=os.path.dirname(os.path.abspath(__file__)));
    who = sys.argv[1];
    node_id = sys.argv[2];
    if who == "guest" {
        um.ensure_internal_user(Con.GUEST.value, "__no_password__");
        rid = str(um.get_root_id(Con.GUEST.value));
    } elif who == "system" {
        rid = str(Jac.get_context().system_root.id);
    } else {
        rid = who;
    }
    print("identity", who, "root", rid);
    print(as_root(rid, node_id, "inproc-" + who[:6]));
}
