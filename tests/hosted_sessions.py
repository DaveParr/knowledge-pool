"""A stand-in for WorkOS's sealed session: no test talks to WorkOS.

A sealed session here is the text `sealed:<sub>:<display name>`. The stand-in
signs in the codes `code-alice`, `code-alice-renamed`, `code-bob` and
`code-nameless`, and refuses any other (a person not on the invite list).
`sealed:<sub>:<name>:old` is a session whose access token has expired, which
`check` renews; one `logout_url` has ended is gone for good."""

from urllib.parse import quote

from browser_session import SessionUser

LOGIN_URL = "https://auth.knowledge-pool.test/authorize"
LOGOUT_URL = "https://auth.knowledge-pool.test/logout"

SIGN_INS = {
    "code-alice": ("user_alice", "Alice Example"),
    "code-alice-renamed": ("user_alice", "Alice Renamed"),
    "code-bob": ("user_bob", "Bob Example"),
    "code-nameless": ("user_nameless", ""),
}


def sealed(sub: str, name: str = "", *, old: bool = False) -> str:
    return f"sealed:{sub}:{name}" + (":old" if old else "")


class StandInSessions:
    def __init__(self):
        self.ended: set[str] = set()

    def login_url(self, state: str, redirect_uri: str) -> str:
        return f"{LOGIN_URL}?state={state}&redirect_uri={quote(redirect_uri, safe='')}"

    def complete_login(self, code: str):
        if code not in SIGN_INS:
            raise PermissionError("not invited")
        sub, name = SIGN_INS[code]
        return sealed(sub, name), SessionUser(sub=sub, name=name)

    def check(self, value: str):
        if not value.startswith("sealed:") or value.removesuffix(":old") in self.ended:
            return None
        parts = value.split(":")
        sub, name = parts[1], parts[2]
        renewed = sealed(sub, name) if value.endswith(":old") else None
        return SessionUser(sub=sub, name=name, sealed=renewed)

    def logout_url(self, value: str, return_to: str):
        if self.check(value) is None:
            return None
        self.ended.add(value.removesuffix(":old"))
        return f"{LOGOUT_URL}?return_to={quote(return_to, safe='')}"
