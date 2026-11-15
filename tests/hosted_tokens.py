"""Test-signed AuthKit tokens: an issuer with a key of its own, so a test can
mint good tokens and tokens that are wrong in one way each."""

import time

import jwt
from cryptography.hazmat.primitives.asymmetric import rsa

ISSUER = "https://auth.knowledge-pool.test"
AUDIENCE = "https://knowledge-pool.test/mcp"


def new_key():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


class TestIssuer:
    """`key_for` is what the verifier asks for the key a token's signature
    must match (production fetches it from AuthKit's JWKS)."""

    __test__ = False

    def __init__(self):
        self.key = new_key()

    def key_for(self, _token: str):
        return self.key.public_key()

    def token(self, sub="user_alice", *, iss=ISSUER, aud=AUDIENCE, expires_in=300, key=None, **claims) -> str:
        now = int(time.time())
        body = {"sub": sub, "iss": iss, "aud": aud, "iat": now, "exp": now + expires_in, **claims}
        return jwt.encode(body, key or self.key, algorithm="RS256", headers={"kid": "test-key"})
