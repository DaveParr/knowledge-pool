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

"""Send the user to sign in and back to the address they are on (edits in progress
are not kept)."""
def signInAgain {
    window.location.assign(signInAddress(window.location.pathname + window.location.search));
}

"""Ask the front door whether the session is still good. If it has ended, send
the user to sign in again and answer None. Otherwise answer the session's reply:
the display name and whether the page offers "Sign out"; a reply that never came
counts as good, so a network blip does not throw the user out."""
async def:pub checkSession -> SessionInfo | None {
    try {
        reply = await fetch(ME_PATH, {"credentials": "same-origin", "headers": {"Accept": "application/json"}});
        if reply.status == 401 {
            signInAgain();
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

glob guardInstalled: bool = False,
     sessionCheckRunning: bool = False;

"""Watch every call the page makes. One that is refused or fails to answer (any
deck call, whether the caller reads it as an empty reply or a thrown error) is
followed by a session check, so a session that has ended sends the user to sign
in instead of showing an empty page. Installed once, by the first SessionBar."""
def installSessionGuard {
    if guardInstalled {
        return;
    }
    guardInstalled = True;
    browser: any = window;  # jac:ignore[W1037]
    original: any = browser.fetch;  # jac:ignore[W1037]

    async def recheck {
        if sessionCheckRunning {
            return;
        }
        sessionCheckRunning = True;
        await checkSession();
        sessionCheckRunning = False;
    }

    browser.fetch = lambda (input: any, init: any) -> any {  # jac:ignore[W1037]
        pending: any = original.call(browser, input, init);  # jac:ignore[W1037]
        pending.then(
            lambda (reply: any) -> any {  # jac:ignore[W1037]
                if not reply.ok and reply.url.indexOf(ME_PATH) < 0 {
                    recheck();
                }
            },
            lambda (_failure: any) -> any {  # jac:ignore[W1037]
                recheck();
            }
        );
        return pending;
    };
}

def:pub SessionBar -> JsxElement {
    has name: str = "",
        signOut: bool = False,
        copied: bool = False,
        address: str = "";

    can with entry {
        installSessionGuard();
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
