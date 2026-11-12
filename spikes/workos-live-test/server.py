"""Throwaway MCP server for the WorkOS AuthKit live test (knowledge-pool issue #102).

Verify-only: AuthKit issues the tokens; this server checks signature, issuer,
audience and expiry against AuthKit's published keys, and has one tool that
says who the caller is. It holds no secrets.

Settings come from the environment, or from a config.env file beside this script:
  AUTHKIT_DOMAIN  the AuthKit domain, e.g. https://example-name-12.authkit.app
  PUBLIC_URL      this server's public origin, e.g. https://x.up.railway.app
  PORT            port to listen on (default 8000)
  JWKS_URL        test override for the keys URL (default AUTHKIT_DOMAIN/oauth2/jwks)
"""

import asyncio
import logging
import os
import time

import jwt
from mcp.server.auth.middleware.auth_context import get_access_token
from mcp.server.auth.provider import AccessToken
from mcp.server.auth.settings import AuthSettings
from mcp.server.mcpserver import MCPServer

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
log = logging.getLogger("live-test")

_config = os.path.join(os.path.dirname(os.path.abspath(__file__)), "config.env")
if os.path.exists(_config):
    for _line in open(_config):
        _name, _sep, _value = _line.strip().partition("=")
        if _sep and not _name.startswith("#"):
            os.environ.setdefault(_name, _value)

ISSUER = os.environ["AUTHKIT_DOMAIN"].rstrip("/")
# Before the public address is known (the first deploy), fall back so the server still starts.
_public = os.environ.get("PUBLIC_URL") or "https://" + os.environ.get("RAILWAY_PUBLIC_DOMAIN", "address-not-set.invalid")
RESOURCE = _public.rstrip("/") + "/mcp"
JWKS_URL = os.environ.get("JWKS_URL", ISSUER + "/oauth2/jwks")


class AuthKitVerifier:
    """Accept only a token AuthKit signed, for this server, that has not expired."""

    def __init__(self) -> None:
        self._keys = jwt.PyJWKClient(JWKS_URL, cache_keys=True)

    def _decode(self, token: str) -> dict:
        key = self._keys.get_signing_key_from_jwt(token)
        return jwt.decode(
            token,
            key.key,
            algorithms=["RS256"],
            issuer=ISSUER,
            audience=RESOURCE,
            options={"require": ["exp", "iss", "aud", "sub"]},
        )

    async def verify_token(self, token: str) -> AccessToken | None:
        try:
            claims = await asyncio.to_thread(self._decode, token)
        except Exception as error:
            # Log what the token claimed, unverified, so a refusal can be diagnosed.
            try:
                seen = jwt.decode(token, options={"verify_signature": False})
                seen = {k: seen.get(k) for k in ("iss", "aud", "sub", "client_id", "exp")}
            except Exception:
                seen = "not a JWT"
            log.info("REFUSED %s: %s; claims seen: %s", type(error).__name__, error, seen)
            return None
        log.info(
            "ACCEPTED sub=%s client_id=%s aud=%s expires_in=%ss",
            claims["sub"], claims.get("client_id"), claims["aud"], claims["exp"] - int(time.time()),
        )
        return AccessToken(
            token=token,
            client_id=str(claims.get("client_id") or claims.get("azp") or "unknown"),
            scopes=str(claims.get("scope", "")).split(),
            expires_at=claims["exp"],
            resource=RESOURCE,
            subject=claims["sub"],
            claims=claims,
        )


server = MCPServer(
    "workos-live-test",
    auth=AuthSettings(issuer_url=ISSUER, resource_server_url=RESOURCE, validate_token_resource=True),
    token_verifier=AuthKitVerifier(),
)


@server.tool()
def whoami() -> dict:
    """Say who the signed-in caller is, from the verified access token."""
    token = get_access_token()
    if token is None:
        return {"error": "no verified token reached the tool"}
    claims = token.claims or {}
    return {
        "sub": token.subject,
        "client_id": token.client_id,
        "registered_by": "CIMD" if token.client_id.startswith("https://") else "DCR or a manual client",
        "iss": claims.get("iss"),
        "aud": claims.get("aud"),
        "seconds_until_expiry": (token.expires_at or 0) - int(time.time()),
        "all_claims": claims,
    }


if __name__ == "__main__":
    log.info("issuer=%s resource=%s keys=%s", ISSUER, RESOURCE, JWKS_URL)
    asyncio.run(
        server.run_streamable_http_async(
            host="0.0.0.0", port=int(os.environ.get("PORT", "8000")), stateless_http=True
        )
    )
