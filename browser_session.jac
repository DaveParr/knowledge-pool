"""Browser sign-in through WorkOS AuthKit, and the sealed session it leaves.

The front door runs AuthKit's redirect and callback itself. What it keeps in
the browser is one cookie holding WorkOS's sealed session (an encrypted
bundle of the access and refresh tokens and the user), sealed with the
cookie password. A session provider is the seam: `WorkOSSessions` is the real
one, over the WorkOS SDK; a test passes a stand-in with the same four methods
(`login_url`, `complete_login`, `check`, `logout_url`) that seals nothing real.
All methods block on the network, so the front door calls them off its
event loop.
"""

import threading;
import time;
import from workos { WorkOSClient }
import from workos.session { AuthenticateWithSessionCookieFailureReason, seal_session_from_auth_response }

glob AUTHKIT_PROVIDER: str = "authkit",
     # How long a renewed session is remembered under the cookie it replaced.
     RENEWAL_MEMORY_S: float = 60.0,
     RENEWALS: dict[str, tuple[float, any]] = {},  # jac:ignore[W1037]
     RENEWAL_LOCK: threading.Lock = threading.Lock();

"""WorkOS was unreachable, or answered in a way that does not say the session
has ended: the session is not known to be over, so the cookie must stay."""
obj SessionCheckUnavailable(Exception) {}

"""Who a session names (`sub` is the WorkOS user id, never an email address)
and, when the access token had to be renewed, the new sealed session to put
in the cookie."""
obj SessionUser {
    has sub: str,
        name: str = "",
        sealed: str | None = None;
}

"""A WorkOS user record as a `SessionUser`: the Google display name is the
first and last name AuthKit holds. None when it names no one."""
def session_user(user: dict[str, any] | None, sealed: str | None = None) -> SessionUser | None {  # jac:ignore[W1037]
    if not user or not isinstance(user.get("id"), str) or not user["id"].strip() {
        return None;
    }
    name = " ".join(p for p in [str(user.get("first_name") or ""), str(user.get("last_name") or "")] if p.strip());
    return SessionUser(sub=user["id"], name=name, sealed=sealed);
}

"""The real provider, over the WorkOS SDK."""
obj WorkOSSessions {
    has client_id: str,
        api_key: str,
        cookie_password: str,
        client: any = None;  # jac:ignore[W1037]

    def postinit {
        self.client = WorkOSClient(api_key=self.api_key, client_id=self.client_id);
    }

    def login_url(state: str, redirect_uri: str) -> str {
        return self.client.user_management.get_authorization_url(  # jac:ignore[E1054,W1051]: the SDK's overloads are not typed for these keywords
            provider=AUTHKIT_PROVIDER, redirect_uri=redirect_uri, state=state
        );
    }

    def complete_login(code: str) -> SessionUser {
        reply = self.client.user_management.authenticate_with_code(code=code);  # jac:ignore[E1054,W1051]
        user = reply.user.to_dict();  # jac:ignore[W1051]
        sealed = seal_session_from_auth_response(  # jac:ignore[E1054,W1051]
            access_token=reply.access_token, refresh_token=reply.refresh_token, user=user,
            cookie_password=self.cookie_password
        );
        signed_in = session_user(user, sealed);
        if signed_in is None {
            raise PermissionError("WorkOS named no user.");
        }
        return signed_in;
    }

    def check(sealed: str) -> SessionUser | None {
        session = self.client.user_management.load_sealed_session(session_data=sealed, cookie_password=self.cookie_password);  # jac:ignore[E1054,W1051]
        found = session.authenticate() as any;  # jac:ignore[W1037,W1051]
        if found.authenticated {
            return session_user(found.user);  # jac:ignore[W1051]
        }
        # An expired access token is renewed here, with the refresh token in the session.
        if found.reason != AuthenticateWithSessionCookieFailureReason.INVALID_JWT {  # jac:ignore[W1051]
            return None;
        }
        renewed = session.refresh() as any;  # jac:ignore[W1037,W1051]
        if not renewed.authenticated {
            # WorkOS refused the refresh token: the session is over. A network error, or a
            # reason this code does not know, is not proof of that.
            if renewed.reason in list(AuthenticateWithSessionCookieFailureReason) and renewed.reason != AuthenticateWithSessionCookieFailureReason.REFRESH_NETWORK_ERROR {  # jac:ignore[W1051]
                return None;
            }
            raise SessionCheckUnavailable(str(renewed.reason));  # jac:ignore[W1051]
        }
        return session_user(renewed.user, renewed.sealed_session);  # jac:ignore[W1051]
    }

    def logout_url(sealed: str, return_to: str) -> str | None {
        session = self.client.user_management.load_sealed_session(session_data=sealed, cookie_password=self.cookie_password);  # jac:ignore[E1054,W1051]
        try {
            return session.get_logout_url(return_to=return_to);  # jac:ignore[W1051]
        } except Exception {
            return None;
        }
    }
}

"""Who `sealed` names, or None when the session has ended; raises
`SessionCheckUnavailable` when that cannot be told. A page load makes
several requests at once with the same cookie, and WorkOS refresh tokens
work once: so one check at a time, and a renewal is remembered for a minute
under the cookie it replaced, so the others get the same answer."""
def check_session(provider: any, sealed: str) -> SessionUser | None {  # jac:ignore[W1037]
    with RENEWAL_LOCK {
        now = time.monotonic();
        for stale in [k for (k, (at, _)) in RENEWALS.items() if now - at > RENEWAL_MEMORY_S] {
            del RENEWALS[stale];
        }
        if sealed in RENEWALS {
            return RENEWALS[sealed][1] as SessionUser;
        }
        try {
            found = provider.check(sealed);
        } except SessionCheckUnavailable {
            raise;
        } except Exception as e {  # the SDK's network and JWKS errors
            raise SessionCheckUnavailable(str(e)) from e;
        }
        if found is not None and found.sealed is not None {
            RENEWALS[sealed] = (now, found);
        }
        return found as SessionUser | None;
    }
}
