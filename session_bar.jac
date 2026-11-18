"""The strip at the top of the page: who is signed in, the connector address
with a copy button, and "Sign out". Also the page's session check."""

import "./session_bar.css";

glob SIGN_IN_PATH: str = "/auth/login",
     SIGN_OUT_PATH: str = "/auth/logout",
     ME_PATH: str = "/me",
     CONNECTOR_PATH: str = "/mcp";

"""What the front door says about the session (`GET /me`)."""
obj SessionInfo {
    has name: str = "",
        sign_out: bool = False;
}

"""Where to send a user whose session has ended: sign in, then back to this address."""
def:pub signInAddress(path: str, search: str) -> str {
    return SIGN_IN_PATH + "?return_to=" + encodeURIComponent(path + search);
}

"""The address claude.ai connects to, on the site the page was served from."""
def:pub connectorAddress(origin: str) -> str {
    return origin + CONNECTOR_PATH;
}

"""Ask the front door whether the session is still good. If it has ended, send
the user to sign in and back to this address, and answer False (edits in
progress are not kept). Otherwise answer the session's reply: the display name
and whether the page offers "Sign out"; a reply that never came counts as good,
so a network blip does not throw the user out."""
async def:pub checkSession -> SessionInfo | None {
    try {
        reply = await fetch(ME_PATH, {"credentials": "same-origin", "headers": {"Accept": "application/json"}});
        if reply.status == 401 {
            window.location.assign(signInAddress(window.location.pathname, window.location.search));
            return None;
        }
        if not reply.ok {
            return SessionInfo();
        }
        body = await reply.json();
        return SessionInfo(name=str(body["name"]), sign_out=bool(body["sign_out"]));
    } except Exception {
        return SessionInfo();
    }
}

def:pub SessionBar -> JsxElement {
    has name: str = "",
        signOut: bool = False,
        copied: bool = False,
        address: str = "";

    can with entry {
        address = connectorAddress(window.location.origin);
        look();
    }

    async def look {
        found = await checkSession();
        if found {
            name = found.name;
            signOut = found.sign_out;
        }
    }

    async def copy {
        try {
            await navigator.clipboard.writeText(address);
            copied = True;
        } except Exception {
            copied = False;
        }
    }

    return
        <header className="sb">
            <span className="sb-who">{name}</span>
            <span className="sb-connector">
                <label>
                    {"Claude connector "}
                    <input type="text" readOnly={True} aria-label="Connector address" value={address}/>
                </label>
                <button type="button" onClick={lambda (_e: MouseEvent) { copy(); }}>
                    {"Copied" if copied else "Copy"}
                </button>
            </span>
            {<form method="post" action={SIGN_OUT_PATH} className="sb-signout">
                <button type="submit" className="link">Sign out</button>
            </form> if signOut else None}
        </header>;
}
