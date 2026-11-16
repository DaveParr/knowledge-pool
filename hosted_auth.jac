"""Hosted mode's token check: who a bearer token names, and the settings
hosted mode cannot start without.

The claude.ai connector reaches the front door with a WorkOS AuthKit access
token. `AuthKitVerifier` is the MCP SDK's verify-only `TokenVerifier`: it
checks the signature against AuthKit's JWKS, the issuer and the audience (the
full public MCP URL) and answers who the token is for, or None. It issues
nothing and keeps no users: the caller is the token's `sub`.
"""

import os;
import time;
import anyio;
import jwt;
import from mcp.server.auth.provider { AccessToken }

glob AUTHKIT_DOMAIN: str = "KP_AUTHKIT_DOMAIN",
     PUBLIC_MCP_URL: str = "KP_PUBLIC_MCP_URL",
     WORKOS_CLIENT_ID: str = "WORKOS_CLIENT_ID",
     WORKOS_API_KEY: str = "WORKOS_API_KEY",
     WORKOS_COOKIE_PASSWORD: str = "WORKOS_COOKIE_PASSWORD",
     # Without it Jac starts a Postgres of its own and every deck is lost on the next deploy.
     DATABASE_URL: str = "JAC_DB_URL",
     HOSTED_SETTINGS: list[str] = [AUTHKIT_DOMAIN, PUBLIC_MCP_URL, WORKOS_CLIENT_ID, WORKOS_API_KEY, WORKOS_COOKIE_PASSWORD, DATABASE_URL],
     JWKS_PATH: str = "/oauth2/jwks",
     ALGORITHMS: list[str] = ["RS256"];

"""Hosted mode was started without one of its settings (the WorkOS ones or the database address)."""
obj HostedSettingsMissing(Exception) {}

"""What hosted mode needs, from the environment. `issuer` is the AuthKit
domain as a URL, `audience` the full public MCP URL."""
obj HostedSettings {
    has issuer: str,
        audience: str,
        client_id: str,
        api_key: str,
        cookie_password: str;
}

"""The hosted settings, or `HostedSettingsMissing` naming every one that is
unset or blank, so a misconfigured deploy fails closed."""
def hosted_settings -> HostedSettings {
    values = {name: os.environ.get(name, "").strip() for name in HOSTED_SETTINGS};
    missing = [name for name in HOSTED_SETTINGS if not values[name]];
    if missing {
        raise HostedSettingsMissing("Hosted mode needs these settings, which are not set: " + ", ".join(missing) + ".");
    }
    domain = values[AUTHKIT_DOMAIN].rstrip("/");
    issuer = domain if "://" in domain else f"https://{domain}";
    return HostedSettings(
        issuer=issuer, audience=values[PUBLIC_MCP_URL], client_id=values[WORKOS_CLIENT_ID],
        api_key=values[WORKOS_API_KEY], cookie_password=values[WORKOS_COOKIE_PASSWORD]
    );
}

"""The function that finds the key a token's signature must match, from
AuthKit's JWKS (fetched by `PyJWKClient`, which caches it)."""
def jwks_key_finder(issuer: str) -> Callable[[str], any] {  # jac:ignore[W1037]
    client = jwt.PyJWKClient(issuer + JWKS_PATH);
    def find(token: str) -> any {  # jac:ignore[W1037]
        return client.get_signing_key_from_jwt(token).key;
    }
    return find;
}

"""The verify-only token verifier. `key_for` finds the key a token's
signature must match; hosted mode passes the JWKS finder, a test its own key."""
obj AuthKitVerifier {
    has issuer: str,
        audience: str,
        key_for: Callable[[str], any];  # jac:ignore[W1037]

    """The token's claims when it is good, else None: signature, issuer,
    audience and expiry all checked, and a `sub` that names someone."""
    def claims(token: str) -> dict[str, any] | None {  # jac:ignore[W1037]
        try {
            decoded = jwt.decode(  # jac:ignore[E1054,W1051]: PyJWT's overloads are not typed for these keywords
                token, self.key_for(token), algorithms=ALGORITHMS, audience=self.audience, issuer=self.issuer,
                options={"require": ["exp", "iss", "aud", "sub"]}
            );
            claims = decoded as dict[str, any];  # jac:ignore[W1037,W1051]
        } except Exception {  # PyJWT's errors, and a key that cannot be fetched
            return None;
        }
        sub = claims.get("sub");
        return claims if isinstance(sub, str) and sub.strip() else None;
    }

    """The MCP SDK's `TokenVerifier` protocol: who the token is for, or None."""
    async def verify_token(token: str) -> AccessToken | None {
        claims = await anyio.to_thread.run_sync(lambda -> dict[str, any] | None { return self.claims(token); });  # jac:ignore[W1037]
        if claims is None {
            return None;
        }
        return AccessToken(
            token=token, client_id=str(claims.get("client_id") or claims["sub"]), scopes=[],
            expires_at=int(claims["exp"]), resource=self.audience, subject=claims["sub"],
            claims={"iss": claims["iss"]}
        );
    }
}
