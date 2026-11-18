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
        can_sign_out: bool = False;
}

"""Where to send a user whose session has ended: sign in, then back to this address."""
def signInAddress(returnTo: str) -> str {
    return SIGN_IN_PATH + "?return_to=" + encodeURIComponent(returnTo);
}

"""The address claude.ai connects to, on the site the page was served from."""
def connectorAddress(origin: str) -> str {
    return origin + CONNECTOR_PATH;
}

"""Ask the front door whether the session is still good. If it has ended, send
the user to sign in and back to this address, and answer None (edits in
progress are not kept). Otherwise answer the session's reply: the display name
and whether the page offers "Sign out"; a reply that never came counts as good,
so a network blip does not throw the user out."""
async def:pub checkSession -> SessionInfo | None {
    try {
        reply = await fetch(ME_PATH, {"credentials": "same-origin", "headers": {"Accept": "application/json"}});
        if reply.status == 401 {
            window.location.assign(signInAddress(window.location.pathname + window.location.search));
            return None;
        }
        if not reply.ok {
            return SessionInfo();
        }
        body = await reply.json();
        return SessionInfo(name=str(body["name"]), can_sign_out=bool(body["can_sign_out"]));
    } except Exception {
        return SessionInfo();
    }
}

"""A walker that reported nothing was refused or never answered: check whether the
session has ended (and if so, send the user to sign in). True if it reported nothing."""
async def:pub checkWhenEmpty(reports: Sequence[object]) -> bool {
    if len(reports) == 0 {
        await checkSession();
        return True;
    }
    return False;
}

def:pub SessionBar -> JsxElement {
    has name: str = "",
        signOut: bool = False,
        copied: bool = False,
        address: str = "";

    can with entry {
        address = connectorAddress(window.location.origin);
        refreshSession();
    }

    async def refreshSession {
        info = await checkSession();
        if info {
            name = info.name;
            signOut = info.can_sign_out;
        }
    }

    async def copyAddress {
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
                <button type="button" onClick={lambda (_e: MouseEvent) { copyAddress(); }}>
                    {"Copied" if copied else "Copy"}
                </button>
            </span>
            {<form method="post" action={SIGN_OUT_PATH} className="sb-signout">
                <button type="submit" className="link">Sign out</button>
            </form> if signOut else None}
        </header>;
}
