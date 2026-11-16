"""A client for the front door (`front_door.jac`): its ASGI app on a test client,
as the local user, with a stub for Jac's server (the page's child) and one for
the MCP SDK's app. The caller is whoever `graph_runner.request_caller` names;
this runs in the test's own process, on the database `JAC_DB_URL` names."""

import httpx2
from jaclang.testing.testing import JacTestClient
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import PlainTextResponse
from starlette.routing import Route
from starlette.testclient import TestClient

import front_door
import hosted_auth
from tests.hosted_tokens import AUDIENCE, ISSUER

ORIGIN = "http://127.0.0.1:8123"
UPSTREAM = "http://upstream.test"


def _mcp_stub() -> Starlette:
    async def answer(request: Request):
        return PlainTextResponse(f"mcp app: {request.url.path}")

    return Starlette(routes=[Route("/mcp", answer), Route("/.well-known/{rest:path}", answer)])


class FrontDoorClient:
    """Calls arrive with the app's own `Origin`, as a browser sends them, unless
    `origin=None`. `upstream_requests` is what reached Jac's server (the stub).
    With `hosted` (a `TestIssuer`), the front door checks bearer tokens signed by it."""

    def __init__(self, base_path, hosted=None, mcp_app=None):
        self._jac = JacTestClient.from_file("main.jac", base_path=str(base_path))
        self.upstream_requests: list[httpx2.Request] = []
        self._upstream_up = True
        http = httpx2.AsyncClient(transport=httpx2.MockTransport(self._upstream))
        auth = None
        if hosted is not None:
            auth = hosted_auth.AuthKitVerifier(issuer=ISSUER, audience=AUDIENCE, key_for=hosted.key_for)
        config = front_door.FrontDoorConfig(upstream=UPSTREAM, origins=[ORIGIN], client=http, auth=auth)
        self._client = TestClient(front_door.front_door_app(mcp_app or _mcp_stub(), config), base_url=ORIGIN)
        # Jac's own test client sets Jac up on `JAC_DB_URL` in this process on its
        # first request, and frees it again on close, so each test has its database.
        assert self._jac.get("/healthz").status_code == 200

    def _upstream(self, request: httpx2.Request) -> httpx2.Response:
        if not self._upstream_up:
            raise httpx2.ConnectError("Jac's server is gone", request=request)
        self.upstream_requests.append(request)
        if request.url.path == "/":
            return httpx2.Response(200, text="<html><title>app</title></html>", headers={"content-type": "text/html"})
        if request.url.path in ("/static/client.js", "/client.BEp6_VCi.js", "/styles.css"):
            return httpx2.Response(200, text="export {}", headers={"content-type": "text/javascript"})
        return httpx2.Response(404, json={"detail": "Not Found"})

    def upstream_down(self) -> None:
        self._upstream_up = False

    def __enter__(self) -> "FrontDoorClient":
        self._client.__enter__()
        return self

    def __exit__(self, *exc) -> None:
        self._client.__exit__(*exc)
        self.close()

    def close(self) -> None:
        self._jac.close()

    def get(self, path: str, headers: dict | None = None) -> httpx2.Response:
        return self._client.get(path, headers=headers)

    def post(self, path: str, json=None, headers: dict | None = None, origin: str | None = ORIGIN) -> httpx2.Response:
        sent = {"origin": origin} if origin else {}
        return self._client.post(path, json=json, headers={**sent, **(headers or {})})
