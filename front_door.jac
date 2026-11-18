"""The front door: the one listener of the app (ADR 0004).

The MCP process answers every request. Jac's own server runs beside it as a
child on 127.0.0.1 and only hands out the web page and its static files; the
front door forwards those two kinds of path and no others. The static files
are under `/static/`, or, for the bundle `jac build --as client` writes (the
hosted image), a script or stylesheet at the root. Every other path
answers 404, so Jac's docs, graph, admin, listing, `/user/*` and `/sso/*`
endpoints are never reachable from outside.

The web page's deck calls, `POST /walker/<name>` and `POST /function/<name>`,
are not forwarded either. The front door runs them itself, through the runner
(`graph_runner.jac`), as the caller, and answers in Jac's own envelope
(`data.reports` for a walker, `data.result` for a function), serialised with
Jac's own serialiser in API mode. The walkers and functions the page calls are
`:protect` (the page does not compile with them plain) and never `:pub`; each
one must be in `WALKERS` or `FUNCTIONS` below as well. Jac's server refuses a
call to them without a Jac token, and no Jac token is ever issued.

A health path answers a bare "ok" without touching Jac, for any host.

In local mode (`KP_MODE=local`) there is no sign-in: the caller is the local
user. The request path is the one hosted mode will use: a caller is found
first, then the request's `Origin` is checked, then the call runs.

Browser sign-in (hosted mode): the front door runs AuthKit's redirect and
callback itself (`/auth/login`, `/auth/callback`; `browser_session.jac`). What
it keeps in the browser is one cookie, `kp_session`, holding WorkOS's sealed
session: HttpOnly, Secure, SameSite=Lax, for the exact host only, rewritten
when the access token is renewed. `/auth/logout` ends the session at WorkOS and
clears the cookie. A request with a bearer token (the connector) or a session
(the browser) runs as that caller; without either, a page load or a page
file is redirected to sign in before anything is served, and every other
request, data calls included, gets a 401. `GET /me` answers the caller's
display name.

The same ASGI app serves `/mcp` (and anything under `/.well-known/`) by
handing it to the MCP SDK's app.
"""

import inspect;
import json;
import os;
import re;
import secrets;
import signal;
import socket;
import subprocess;
import sys;
import threading;
import time;
import atexit;
import anyio;
import httpx2;
import from starlette.applications { Starlette }
import from starlette.requests { Request }
import from urllib.parse { quote, unquote }
import from starlette.responses { Response, JSONResponse, PlainTextResponse, RedirectResponse }
import from starlette.routing { Route }
import from jaclang.data.serializer { Serializer }
import from mcp.server.auth.routes { build_resource_metadata_url }
import from pydantic { AnyHttpUrl }
import from graph_runner { APP_DIR, HOSTED, VERIFIED_SUB, app_mode, request_caller, run_walker, call_function, CallFailed }
import from profile { save_display_name, display_name }
import from browser_session { SessionUser, SessionCheckUnavailable, check_session }
import from hosted_auth { AuthKitVerifier }
import from decks { CreateDeck, ListDecks, GetDeck, SetDeckFormat, AddCard, SetCardCount, RemoveCard, list_formats }
import from deck_io { DeckExport, DeckImport, CreateDeckFromList }
import from cards { search_cards }

glob HEALTH_PATH: str = "/healthz",
     # The built bundle's script and stylesheet, which its page loads from the root.
     ROOT_ASSET: re.Pattern = re.compile(r"/client\.[A-Za-z0-9_-]+\.js|/styles\.css"),
     LOOPBACK: str = "127.0.0.1",
     # The MCP SDK's app answers these paths (the connector, and later its OAuth discovery).
     MCP_PREFIXES: list[str] = ["/mcp", "/.well-known/"],
     # What the page may call. Adding one to the page means adding it here, as `:protect`.
     WALKERS: dict[str, any] = {  # jac:ignore[W1037]
         "CreateDeck": CreateDeck,
         "ListDecks": ListDecks,
         "GetDeck": GetDeck,
         "SetDeckFormat": SetDeckFormat,
         "AddCard": AddCard,
         "SetCardCount": SetCardCount,
         "RemoveCard": RemoveCard,
         "DeckExport": DeckExport,
         "DeckImport": DeckImport,
         "CreateDeckFromList": CreateDeckFromList
     },
     FUNCTIONS: dict[str, any] = {"list_formats": list_formats, "search_cards": search_cards},  # jac:ignore[W1037]
     # The request headers worth passing to Jac's server for the page and its files.
     FORWARDED_REQUEST_HEADERS: list[str] = ["accept", "if-none-match", "if-modified-since"],
     FORWARDED_RESPONSE_HEADERS: list[str] = ["content-type", "cache-control", "etag", "last-modified"],
     # What a connector may fetch without a token: the metadata that says where to sign in.
     DISCOVERY_PATH: str = "/.well-known/oauth-protected-resource",
     # `__Host-` makes the browser itself insist on Secure, Path=/ and no Domain: the exact host only.
     SESSION_COOKIE: str = "__Host-kp_session",
     LOGIN_COOKIE: str = "__Host-kp_login",
     LOGIN_PATH: str = "/auth/login",
     CALLBACK_PATH: str = "/auth/callback",
     LOGOUT_PATH: str = "/auth/logout",
     AUTH_PATHS: list[str] = [LOGIN_PATH, CALLBACK_PATH, LOGOUT_PATH],
     # A path on this site and nothing a browser could read as another address (no tab, space, backslash).
     SAFE_RETURN: re.Pattern = re.compile(r"/(?!/)[A-Za-z0-9._~!$&'()*+,;=:@%/?-]*"),
     ME_PATH: str = "/me",
     # The longest a browser keeps a cookie; the session itself ends when WorkOS says so.
     SESSION_MAX_AGE_S: int = 400 * 24 * 3600,
     LOGIN_MAX_AGE_S: int = 600,
     NO_STORE: dict[str, str] = {"cache-control": "no-store"},
     UPSTREAM_BOOT_S: float = 120.0,
     STOPPING: list[bool] = [];

"""What a front door needs to know: where Jac's server listens (`upstream`),
the `Origin`s of its own page (the only ones a browser data call may carry),
the HTTP client that reaches the upstream (a test passes one on a stub), and in
hosted mode the verifier of bearer tokens (`auth`; hosted mode without one
refuses every request), the browser sign-in (`sessions`, see
`browser_session.jac`) and the address the page is served from
(`public_origin`, where AuthKit sends the browser back to)."""
obj FrontDoorConfig {
    has upstream: str,
        origins: list[str],
        client: any = None,  # jac:ignore[W1037]
        auth: AuthKitVerifier | None = None,
        sessions: any = None,  # jac:ignore[W1037]
        public_origin: str = "";
}

"""Jac's own error envelope, with the HTTP status Jac's server would use."""
def refusal(status: int, code: str, message: str) -> Response {
    return JSONResponse(
        {"ok": False, "type": "error", "data": None, "error": {"code": code, "message": message}}, status_code=status
    );
}

"""Jac's own reply envelope for a finished walker or function call."""
def envelope(result: any, reports: any) -> dict[str, any] {  # jac:ignore[W1037]
    return {
        "ok": True,
        "type": "response",
        "data": {
            "result": Serializer.serialize(result, api_mode=True),
            "reports": Serializer.serialize(reports, api_mode=True)
        },
        "error": None
    };
}

"""A call the runner could not finish, as the reply the page shows through
its failure display."""
def failed_call(failed: CallFailed) -> Response {
    status = 503 if failed.error.code == "try-again" else 500;
    return refusal(status, failed.error.code.upper(), failed.error.message);
}

"""Why a browser data call is refused before it runs, or None to let it run.
The caller comes first (no caller is a 401), then the request's `Origin`."""
def check_data_call(request: Request, config: FrontDoorConfig) -> tuple[str | None, Response | None] {  # jac:ignore[W1036]
    caller = request_caller();
    if caller is None {
        return (None, refusal(401, "UNAUTHORIZED", "Unauthorized"));
    }
    if request.headers.get("origin") not in config.origins {
        return (None, refusal(403, "FORBIDDEN", "Forbidden"));
    }
    return (caller, None);
}

"""The call's fields from the request body: a JSON object, or None."""
async def read_fields(request: Request) -> dict[str, any] | None {  # jac:ignore[W1036,W1037]
    raw = await request.body();
    if not raw {
        return {};
    }
    try {
        fields = json.loads(raw);
    } except ValueError {
        return None;
    }
    return fields if isinstance(fields, dict) else None;
}

"""Whether `fields` fit `target`'s parameters: no unknown field, none missing,
and no `reports` (a walker's output is not the caller's to set)."""
def fits(target: any, fields: dict[str, any]) -> bool {  # jac:ignore[W1037]
    if "reports" in fields {
        return False;
    }
    try {
        inspect.signature(target).bind(**fields);
    } except TypeError {
        return False;
    }
    return True;
}

"""`POST /walker/<name>`: run the walker as the caller, answer in Jac's envelope."""
async def walker_call(request: Request, config: FrontDoorConfig) -> Response {  # jac:ignore[W1036]
    (caller, refused) = check_data_call(request, config);
    if refused is not None {
        return refused;
    }
    cls = WALKERS.get(str(request.path_params["name"]));
    if cls is None {
        return refusal(404, "NOT_FOUND", "Not Found");
    }
    fields = await read_fields(request);
    if fields is None or not fits(cls, fields) {
        return refusal(422, "INVALID_REQUEST", "The call's fields do not fit this walker.");
    }
    w = cls(**fields);
    done = await anyio.to_thread.run_sync(lambda -> any { return run_walker(caller, w); });
    return JSONResponse(envelope(done, done.reports));
}

"""`POST /function/<name>`: call the function as the caller, answer in Jac's envelope."""
async def function_call(request: Request, config: FrontDoorConfig) -> Response {  # jac:ignore[W1036]
    (caller, refused) = check_data_call(request, config);
    if refused is not None {
        return refused;
    }
    fn = FUNCTIONS.get(str(request.path_params["name"]));
    if fn is None {
        return refusal(404, "NOT_FOUND", "Not Found");
    }
    args = await read_fields(request);
    if args is None or not fits(fn, args) {
        return refusal(422, "INVALID_REQUEST", "The call's arguments do not fit this function.");
    }
    try {
        result = await anyio.to_thread.run_sync(
            lambda -> any { return call_function(caller, lambda -> any { return fn(**args); }, name=fn.__name__); }
        );
    } except CallFailed as failed {
        return failed_call(failed);
    }
    return JSONResponse(envelope(result, []));
}

"""Whether `path` is the page or one of its static files: the only paths
forwarded to Jac's server. Nothing that climbs out of `/static/`; at the root,
only a built bundle's script or stylesheet (`/client.<hash>.js`, `/styles.css`)."""
def is_page_path(path: str) -> bool {
    if path == "/" or ROOT_ASSET.fullmatch(path) {
        return True;
    }
    return path.startswith("/static/") and ".." not in path and "//" not in path and "%" not in path;
}

"""Hand the page and its static files out from Jac's server. No cookie, no
`Authorization` header and no body goes with the request."""
async def forward_page(request: Request, config: FrontDoorConfig) -> Response {  # jac:ignore[W1036]
    sent = {k: v for (k, v) in request.headers.items() if k.lower() in FORWARDED_REQUEST_HEADERS};
    sent["accept-encoding"] = "identity";
    try {
        up = await config.client.request(
            request.method, config.upstream + request.url.path, params=request.url.query, headers=sent
        );
    } except httpx2.HTTPError {
        return PlainTextResponse("Bad gateway", status_code=502);
    }
    kept = {k: v for (k, v) in up.headers.items() if k.lower() in FORWARDED_RESPONSE_HEADERS};
    return Response(content=up.content, status_code=up.status_code, headers=kept);
}

"""Everything else: the page and its files, or 404."""
async def other(request: Request, config: FrontDoorConfig) -> Response {  # jac:ignore[W1036]
    if request.method in ["GET", "HEAD"] and is_page_path(request.url.path) {
        return await forward_page(request, config);
    }
    return PlainTextResponse("Not Found", status_code=404);
}

async def health(_request: Request) -> Response {  # jac:ignore[W1036]
    return PlainTextResponse("ok");
}

"""A cookie as a `Set-Cookie` header value: HttpOnly, Secure, SameSite=Lax, no
Domain (so for the exact host only), for the whole site. Max-Age 0 deletes it."""
def cookie_header(name: str, value: str, max_age: int) -> str {
    return f"{name}={value}; Max-Age={max_age}; Path=/; HttpOnly; Secure; SameSite=Lax";
}

"""`where` if it is a path on this site, else "/": a sign-in must never send the
browser to another address."""
def safe_return(where: str) -> str {
    return where if SAFE_RETURN.fullmatch(where) else "/";
}

"""The sign-in page's address for a request that may not have it: the current
address is where the user returns to."""
def login_redirect(path: str, query: str) -> str {
    here = path + ("?" + query if query else "");
    return f"{LOGIN_PATH}?return_to={quote(here, safe='')}";
}

"""A redirect that no cache keeps."""
def redirect(where: str, status: int = 302) -> RedirectResponse {
    return RedirectResponse(where, status_code=status, headers=NO_STORE);
}

"""Run `work` as `caller` on their own root, off the event loop; a call the runner
could not finish is answered as a failed call."""
async def as_caller(caller: str, work: Callable[[], any], name: str) -> tuple[any, Response | None] {  # jac:ignore[W1036,W1037]
    try {
        done = await anyio.to_thread.run_sync(lambda -> any { return call_function(caller, work, name=name); });
    } except CallFailed as failed {
        return (None, failed_call(failed));
    }
    return (done, None);
}

"""`GET /auth/login`: send the browser to AuthKit, remembering where it came from."""
async def login(request: Request, config: FrontDoorConfig) -> Response {  # jac:ignore[W1036]
    state = secrets.token_urlsafe(24);
    return_path = safe_return(request.query_params.get("return_to", "/"));
    where = await anyio.to_thread.run_sync(
        lambda -> str { return config.sessions.login_url(state, config.public_origin + CALLBACK_PATH); }
    );
    reply = redirect(where);
    reply.headers.append("set-cookie", cookie_header(LOGIN_COOKIE, f"{state}.{quote(return_path, safe='')}", LOGIN_MAX_AGE_S));
    return reply;
}

"""`GET /auth/callback`: AuthKit sent the browser back with a code. Trade it for the
sealed session, store the user's display name on their own root, set the session
cookie and return to where the user was going. A person WorkOS refuses (not
invited, another address) gets a 403 and no cookie."""
async def callback(request: Request, config: FrontDoorConfig) -> Response {  # jac:ignore[W1036]
    code = request.query_params.get("code", "");
    state = request.query_params.get("state", "");
    (expected_state, _, quoted_return) = request.cookies.get(LOGIN_COOKIE, "").partition(".");
    if not code or not expected_state or not secrets.compare_digest(state, expected_state) {
        return PlainTextResponse("Sign-in could not be completed. Start again.", status_code=400, headers=NO_STORE);
    }
    try {
        user = await anyio.to_thread.run_sync(lambda -> SessionUser { return config.sessions.complete_login(code); });
    } except Exception {
        return PlainTextResponse("Sign-in refused.", status_code=403, headers=NO_STORE);
    }
    (_, failed) = await as_caller(user.sub, lambda -> any { return save_display_name(user.name); }, "save_display_name");
    if failed is not None {
        return failed;
    }
    reply = redirect(safe_return(unquote(quoted_return)));
    reply.headers.append("set-cookie", cookie_header(SESSION_COOKIE, user.sealed or "", SESSION_MAX_AGE_S));
    reply.headers.append("set-cookie", cookie_header(LOGIN_COOKIE, "", 0));
    return reply;
}

"""`POST /auth/logout`: end the session at WorkOS, clear the cookie and go to the
site's root. A POST from the app's own page only, so another site cannot sign a
user out with a link."""
async def logout(request: Request, config: FrontDoorConfig) -> Response {  # jac:ignore[W1036]
    if request.headers.get("origin") not in config.origins {
        return refusal(403, "FORBIDDEN", "Forbidden");
    }
    sealed = request.cookies.get(SESSION_COOKIE, "");
    where: str | None = None;
    if sealed {
        where = await anyio.to_thread.run_sync(
            lambda -> str | None { return config.sessions.logout_url(sealed, config.public_origin + "/"); }
        );
    }
    reply = redirect(where or "/", 303);
    reply.headers.append("set-cookie", cookie_header(SESSION_COOKIE, "", 0));
    return reply;
}

"""`GET /me`, the session check for the page: the caller's display name, or
"Unknown user" when none is stored yet, and whether the page may offer "Sign out"
(only where a browser session exists to end)."""
async def session_check(config: FrontDoorConfig) -> Response {
    caller = request_caller();
    if caller is None {
        return refusal(401, "UNAUTHORIZED", "Unauthorized");
    }
    (name, failed) = await as_caller(caller, display_name, "display_name");
    if failed is not None {
        return failed;
    }
    return JSONResponse({"name": name, "can_sign_out": browser_sign_in_enabled(config)}, headers=NO_STORE);
}

"""Whether browser sign-in is on: hosted mode with a session provider."""
def browser_sign_in_enabled(config: FrontDoorConfig) -> bool {
    return app_mode() == HOSTED and config.sessions is not None;
}

"""A route that answers 404 unless browser sign-in is on (hosted mode with a session provider)."""
def sign_in_route(handler: any, config: FrontDoorConfig) -> any {  # jac:ignore[W1036,W1037]
    async def route(request: Request) -> Response {  # jac:ignore[W1036]
        if not browser_sign_in_enabled(config) {
            return PlainTextResponse("Not Found", status_code=404);
        }
        return await handler(request, config);
    }
    return route;
}

"""The front door's own routes, apart from the MCP SDK's."""
def web_app(config: FrontDoorConfig) -> Starlette {
    async def walker_route(request: Request) -> Response {  # jac:ignore[W1036]
        return await walker_call(request, config);
    }
    async def function_route(request: Request) -> Response {  # jac:ignore[W1036]
        return await function_call(request, config);
    }
    async def other_route(request: Request) -> Response {  # jac:ignore[W1036]
        return await other(request, config);
    }
    async def me_route(_request: Request) -> Response {  # jac:ignore[W1036]
        return await session_check(config);
    }
    return Starlette(
        routes=[
            Route(HEALTH_PATH, health, methods=["GET", "HEAD"]),
            Route(LOGIN_PATH, sign_in_route(login, config), methods=["GET"]),
            Route(CALLBACK_PATH, sign_in_route(callback, config), methods=["GET"]),
            Route(LOGOUT_PATH, sign_in_route(logout, config), methods=["POST"]),
            Route(ME_PATH, me_route, methods=["GET"]),
            Route("/walker/{name}", walker_route, methods=["POST"]),
            Route("/function/{name}", function_route, methods=["POST"]),
            Route("/{path:path}", other_route, methods=["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"])
        ]
    );
}

"""Whether `path` is one the MCP SDK's app answers."""
def is_mcp_path(path: str) -> bool {
    return any(path == p.rstrip("/") or path.startswith(p if p.endswith("/") else p + "/") for p in MCP_PREFIXES);
}

"""The one ASGI app: the MCP SDK's app (`mcp_app`) answers the connector's
paths and its own start-up and shut-down; the front door's routes answer
the rest."""
def front_door_app(mcp_app: any, config: FrontDoorConfig) -> any {  # jac:ignore[W1037]
    web = web_app(config);
    async def app(scope: dict[str, any], receive: any, send: any) {  # jac:ignore[W1037]
        if scope["type"] == "lifespan" or (scope["type"] == "http" and is_mcp_path(scope["path"])) {
            await mcp_app(scope, receive, send);
        } else {
            await web(scope, receive, send);
        }
    }
    return guarded(app, config);
}

"""The bearer token a request carries, or None."""
def bearer_token(scope: dict[str, any]) -> str | None {  # jac:ignore[W1037]
    for (name, value) in scope["headers"] {
        if name == b"authorization" {
            (kind, _, token) = value.decode("latin-1").partition(" ");
            return token.strip() or None if kind.lower() == "bearer" else None;
        }
    }
    return None;
}

"""Whether `path` is the discovery metadata (for the connector's resource URL
too, which adds its own path)."""
def is_discovery_path(path: str) -> bool {
    return path == DISCOVERY_PATH or path.startswith(DISCOVERY_PATH + "/");
}

"""The reply to a request without a valid token: 401, naming where the
connector finds how to sign in (RFC 9728)."""
def unauthorized(auth: AuthKitVerifier | None) -> Response {
    reply = refusal(401, "UNAUTHORIZED", "Unauthorized");
    if auth is not None {
        reply.headers["www-authenticate"] = f'Bearer resource_metadata="{build_resource_metadata_url(AnyHttpUrl(auth.audience))}"';
    } else {
        reply.headers["www-authenticate"] = "Bearer";
    }
    return reply;
}

"""The discovery metadata (RFC 9728): this resource, and the AuthKit that signs its tokens."""
def discovery(auth: AuthKitVerifier) -> Response {
    return JSONResponse({
        "resource": auth.audience,
        "authorization_servers": [auth.issuer],
        "bearer_methods_supported": ["header"]
    });
}

"""`send`, changed so the response it carries also sets `cookie`."""
def send_with_cookie(send: any, cookie: str) -> any {  # jac:ignore[W1037]
    async def wrapped(message: dict[str, any]) {  # jac:ignore[W1037]
        if message["type"] == "http.response.start" {
            message = {**message, "headers": [*message.get("headers", []), (b"set-cookie", cookie.encode("latin-1"))]};
        }
        await send(message);
    }
    return wrapped;
}

"""What a request's credentials say: the `caller` (a WorkOS user id) or None;
the `renewed` session cookie to send back, when the access token was renewed;
and whether the request carried a session `ended`."""
obj Credentials {
    has caller: str | None = None,
        renewed: str | None = None,
        ended: bool = False;
}

"""Who a request is from: its bearer token, or for a path the connector does
not use, its session cookie. Raises `SessionCheckUnavailable` when WorkOS
cannot say whether the session is still good."""
async def credentials(scope: dict[str, any], config: FrontDoorConfig) -> Credentials {  # jac:ignore[W1037]
    token = bearer_token(scope);
    access = await config.auth.verify_token(token) if config.auth is not None and token else None;
    if access is not None {
        return Credentials(caller=access.subject);
    }
    sealed = Request(scope).cookies.get(SESSION_COOKIE, "");
    if config.sessions is None or is_mcp_path(scope["path"]) or not sealed {
        return Credentials();
    }
    session_user = await anyio.to_thread.run_sync(lambda -> SessionUser | None { return check_session(config.sessions, sealed); });
    if session_user is None {
        return Credentials(ended=True);
    }
    return Credentials(caller=session_user.sub, renewed=session_user.sealed);
}

"""The reply to a request from no one: a page load or a page file is sent to
sign in; anything else gets a 401. A session that has ended is cleared."""
def refuse_anonymous(request: Request, config: FrontDoorConfig, ended: bool) -> Response {
    reply: Response;
    if config.sessions is not None and request.method in ["GET", "HEAD"] and is_page_path(request.url.path) {
        reply = redirect(login_redirect(request.url.path, request.url.query));
    } else {
        reply = unauthorized(config.auth);
    }
    if ended {
        reply.headers.append("set-cookie", cookie_header(SESSION_COOKIE, "", 0));
    }
    return reply;
}

"""The ASGI app, behind the sign-in check of hosted mode. The health path,
discovery and the sign-in paths answer anyone. Every other request runs as
the caller its credentials name (`graph_runner.VERIFIED_SUB`, which
`graph_runner.request_caller` reads); a session whose access token has
expired is renewed and the renewed cookie goes out with the response. A
request from no one gets, for a page load or a page file, a redirect to
sign in (before anything is served: a page served with no caller would
reload for ever on its first 401), and for anything else a 401. If WorkOS
cannot say whether a session is good, the answer is 503 and the cookie
stays. Local mode has no check."""
def guarded(inner: any, config: FrontDoorConfig) -> any {  # jac:ignore[W1037]
    async def app(scope: dict[str, any], receive: any, send: any) {  # jac:ignore[W1037]
        if scope["type"] != "http" {
            await inner(scope, receive, send);
            return;
        }
        path = scope["path"];
        if app_mode() != HOSTED or path == HEALTH_PATH or path in AUTH_PATHS {
            await inner(scope, receive, send);
            return;
        }
        if config.auth is not None and is_discovery_path(path) {
            await discovery(config.auth)(scope, receive, send);
            return;
        }
        try {
            who = await credentials(scope, config);
        } except SessionCheckUnavailable {
            await PlainTextResponse("Sign-in is unavailable. Try again.", status_code=503, headers=NO_STORE)(scope, receive, send);
            return;
        }
        if who.caller is None {
            await refuse_anonymous(Request(scope), config, who.ended)(scope, receive, send);
            return;
        }
        reset = VERIFIED_SUB.set(who.caller);
        try {
            if who.renewed is not None {
                send = send_with_cookie(send, cookie_header(SESSION_COOKIE, who.renewed, SESSION_MAX_AGE_S));
            }
            await inner(scope, receive, send);
        } finally {
            VERIFIED_SUB.reset(reset);
        }
    }
    return app;
}

"""A TCP port nothing listens on now."""
def free_port -> int {
    with socket.socket() as s {
        s.bind((LOOPBACK, 0));
        return s.getsockname()[1];
    }
}

"""Start Jac's server for the page as a child, on 127.0.0.1 only (`port`;
a free one when 0). One worker, docs and graph off and registration off come
from `jac.toml`. Returns the child and its URL once it answers, or raises."""
def start_upstream(port: int = 0) -> tuple[subprocess.Popen, str] {  # jac:ignore[W1036]
    port = port or free_port();
    child = subprocess.Popen(
        [sys.executable, "run", "--no-dev", "--host", LOOPBACK, "--port", str(port), "main.jac"],
        cwd=APP_DIR, stdin=subprocess.DEVNULL, stdout=sys.stderr, stderr=sys.stderr
    );
    atexit.register(stop_upstream, child);
    url = f"http://{LOOPBACK}:{port}";
    deadline = time.monotonic() + UPSTREAM_BOOT_S;
    while time.monotonic() < deadline {
        if child.poll() is not None {
            raise RuntimeError(f"Jac's server for the page exited with code {child.returncode} at start.");
        }
        try {
            with socket.create_connection((LOOPBACK, port), timeout=1) {
                return (child, url);
            }
        } except OSError {
            time.sleep(0.5);
        }
    }
    stop_upstream(child);
    raise RuntimeError(f"Jac's server for the page did not listen on {url} within {UPSTREAM_BOOT_S:.0f}s.");
}

"""Stop the child, if it still runs."""
def stop_upstream(child: subprocess.Popen) {  # jac:ignore[W1036]
    if child.poll() is None {
        child.terminate();
        try {
            child.wait(timeout=10);
        } except subprocess.TimeoutExpired {
            child.kill();
        }
    }
}

"""Stop the child when the front door is told to stop (SIGTERM). Uvicorn shuts down
and then re-raises the signal with the handler it found, which by default ends the
process without running `finally` or `atexit`; this handler is the one it finds."""
def stop_child_on_sigterm(child: subprocess.Popen) {  # jac:ignore[W1036]
    def stop(signum: int, frame: object) {  # jac:ignore[W1036,W1037,W2003]
        expect_upstream_to_stop();
        stop_upstream(child);
        raise SystemExit(128 + signum);
    }
    signal.signal(signal.SIGTERM, stop);
}

"""If the child dies while the front door serves, the front door exits (the
page would be gone, and a restart policy can bring both back)."""
def exit_when_upstream_dies(child: subprocess.Popen) {  # jac:ignore[W1036]
    def watch {
        code = child.wait();
        if not STOPPING {
            sys.stderr.write(f"Jac's server for the page died with code {code}: the front door exits.\n");
            sys.stderr.flush();
            os._exit(1);
        }
    }
    threading.Thread(target=watch, daemon=True).start();
}

"""Tell the watcher that the child's end is expected."""
def expect_upstream_to_stop {
    STOPPING.append(True);
}
