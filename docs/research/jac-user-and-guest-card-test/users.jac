"""Ticket 110 part 1: users named by a WorkOS id."""
import os;
import json;
import from jaclang { JacRuntime as Jac }
import from jaclang.runtime.constants { Constants as Con }

def show(label: str, v: any) {
    print(label + ": " + json.dumps(v, `default=str));
}

with entry {
    um = Jac.get_user_manager(base_path=os.path.dirname(os.path.abspath(__file__)));
    wid = "user_01KP110ZZTESTA";
    show("A exists before", um.user_exists(wid));
    r1 = um.ensure_user_root(wid);
    r2 = um.ensure_user_root(wid);
    show("A ensure_user_root twice", [r1, r2, r1 == r2]);
    show("A get_root_id", um.get_root_id(wid));
    show("A get_user", um.get_user(wid));
    show("A authenticate ''", um.authenticate(wid, "", "t1"));
    show("A authenticate __no_password__", um.authenticate(wid, "__no_password__", "t2"));
    show("A is_password_required", um.is_password_required(wid));

    wib = "user_01KP110ZZTESTB";
    c1 = um.ensure_internal_user(wib, "__no_password__");
    c2 = um.ensure_internal_user(wib, "__no_password__");
    show("B ensure_internal_user twice", [c1.get("user_id"), c2.get("user_id"), c1.get("root_id"), c2.get("root_id"), c1.get("error")]);
    show("B get_root_id by name", um.get_root_id(wib));
    show("B authenticate __no_password__", um.authenticate(wib, "__no_password__", "t3"));
    show("B authenticate wrong", um.authenticate(wib, "nope", "t4"));
    show("guest authenticate __no_password__", um.authenticate(Con.GUEST.value, "__no_password__", "t5"));

    # collision: someone holds the username "user_01kp110zztestc" before the WorkOS user of that id first arrives
    wic = "user_01KP110ZZTESTC";
    squat = um.create_internal_user(wic, "squatter-password-123");
    show("C squatter", [squat.get("user_id"), squat.get("root_id"), squat.get("error")]);
    show("C get_root_id(workos id) before provisioning", um.get_root_id(wic));
    rc = um.ensure_user_root(wic);
    show("C ensure_user_root", rc);
    show("C get_root_id after", um.get_root_id(wic));
    show("C user_exists / get_user id", [um.user_exists(wic), (um.get_user(wic) or {}).get("user_id")]);
}
