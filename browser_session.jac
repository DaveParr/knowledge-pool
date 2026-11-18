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

import from workos { WorkOSClient }
import from workos.session { AuthenticateWithSessionCookieFailureReason, seal_session_from_auth_response }

glob AUTHKIT_PROVIDER: str = "authkit";

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

    def complete_login(code: str) -> tuple[str, SessionUser] {  # jac:ignore[W1036]
        reply = self.client.user_management.authenticate_with_code(code=code);  # jac:ignore[E1054,W1051]
        user = reply.user.to_dict();  # jac:ignore[W1051]
        sealed = seal_session_from_auth_response(  # jac:ignore[E1054,W1051]
            access_token=reply.access_token, refresh_token=reply.refresh_token, user=user,
            cookie_password=self.cookie_password
        );
        who = session_user(user);
        if who is None {
            raise PermissionError("WorkOS named no user.");
        }
        return (sealed, who);
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
            return None;
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
