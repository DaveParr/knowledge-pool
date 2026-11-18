"""What the app keeps about a user: their Google display name, on their own
root, set at each browser sign-in. The app has no user table of its own."""

glob UNKNOWN_USER: str = "Unknown user";

node Profile {
    has display_name: str = "";
}

"""Store `name` as the display name on the caller's own root. A blank name
changes nothing."""
def save_display_name(name: str) {
    if not name.strip() {
        return;
    }
    found = [root-->[?:Profile]];
    if found {
        found[0].display_name = name.strip();
    } else {
        root ++> Profile(display_name=name.strip());
    }
}

"""The caller's display name, or "Unknown user" when none is stored yet."""
def display_name -> str {
    found = [root-->[?:Profile]];
    return found[0].display_name if found and found[0].display_name else UNKNOWN_USER;
}
