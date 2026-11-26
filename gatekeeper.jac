"""The gatekeeper: who is asking, and whether they may (ADR 0004).

It checks credentials, runs the browser sign-in and applies the rate limits, and
yields an explicit `Caller` for every request it lets through. Nothing past it
works out who is asking: the runner and deck operations take the caller as an
argument only, and the deck-call endpoint (`deck_call.jac`) takes the `Caller`
this module hands it.

A request with a bearer token (the connector) or a session (the browser) runs as
that caller; without either, a page load or a page file is redirected to sign in
before anything is served, and every other request, data calls included, gets a
401. Browser sign-in (hosted mode): AuthKit's redirect and callback
(`/auth/login`, `/auth/callback`; `browser_session.jac`) and `/auth/logout`. What
it keeps in the browser is one cookie, holding WorkOS's sealed session: HttpOnly,
Secure, SameSite=Lax, for the exact host only, rewritten when the access token is
renewed. `GET /me` answers the caller's display name.

In local mode (`KP_MODE=local`) there is no sign-in and no limit: the caller is
the local user.

`guarded` wraps the whole ASGI app, and in hosted mode sets the verified caller
for the request being served. The MCP tools read it through `request_caller`, the
web page's deck calls through `current_caller` (`check_data_call`): the one way a
caller is worked out.
"""

import contextvars;
import re;
import secrets;
import anyio;
import from starlette.requests { Request }
import from urllib.parse { quote, unquote }
import from starlette.responses { Response, JSONResponse, PlainTextResponse, RedirectResponse }
import from starlette.routing { Route }
import from mcp.server.auth.routes { build_resource_metadata_url }
import from pydantic { AnyHttpUrl }
import from graph_runner { HOSTED, LOCAL, LOCAL_USER, app_mode, call_function }
import from profile { save_display_name, display_name }
import from browser_session { SessionUser, SessionCheckUnavailable, check_session }
import from hosted_auth { AuthKitVerifier }
import from rate_limits { Buckets, RateLimits, rate_limits, UNKNOWN_ADDRESS }
import from replies { refusal, failed_call }
import from walker_errors { WalkerError }

glob HEALTH_PATH: str = "/healthz",
     # The built bundle's script and stylesheet, which its page loads from the root.
     ROOT_ASSET: re.Pattern = re.compile(r"/client\.[A-Za-z0-9_-]+\.js|/styles\.css"),
     # The page's icons (`public/icons/<set>/<file>`), linked from its head.
     ICON_ASSET: re.Pattern = re.compile(r"/icons/(web-and-mobile|transparent|light|dark)/[A-Za-z0-9_.-]+\.(png|ico)"),
     # The MCP SDK's app answers these paths (the connector, and later its OAuth discovery).
     MCP_PREFIXES: list[str] = ["/mcp", "/.well-known/"],
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
     # The `sub` of the token the gatekeeper verified for the request being served (hosted mode).
     VERIFIED_SUB: contextvars.ContextVar[str | None] = contextvars.ContextVar("verified_sub");

"""Who is asking: the user whose id (`user_id`, a WorkOS `sub`, or the local
user's) the call runs as. The one value that carries identity from the gatekeeper
to the runner."""
obj Caller {
    has user_id: str;
}

"""What the gatekeeper needs to know: the `Origin`s of the app's own page (the
only ones a browser data call may carry), in hosted mode the verifier of bearer
tokens (`auth`; hosted mode without one refuses every request), the browser
sign-in (`sessions`, see `browser_session.jac`), the address the page is served
from (`public_origin`, where AuthKit sends the browser back to) and the rate
limits (`limits`; None reads them from the environment)."""
obj GatekeeperConfig {
    has origins: list[str],
        auth: AuthKitVerifier | None = None,
        sessions: any = None,  # jac:ignore[W1037]
        public_origin: str = "",
        limits: RateLimits | None = None;
}

"""The caller of the request being served: the local user in local mode. In
hosted mode, the one `guarded` verified for this request, read here and nowhere
else. No verified token means no caller, and every call is refused: never a
fallback to the guest."""
def current_caller -> Caller | None {
    if app_mode() == LOCAL {
        return Caller(user_id=LOCAL_USER);
    }
    sub = VERIFIED_SUB.get(None);
    return Caller(user_id=sub) if sub else None;
}

"""`current_caller`'s id, for the MCP tools, whose calls take the caller as an
id (`perform`)."""
def request_caller -> str | None {
    caller = current_caller();
    return caller.user_id if caller is not None else None;
}

"""Whether the request's `Origin` is one of the app's own page."""
def from_own_page(request: Request, config: GatekeeperConfig) -> bool {  # jac:ignore[W1036]
    return request.headers.get("origin") in config.origins;
}

"""The caller of a browser data call, or the refusal to answer it with. The
caller comes first (no caller is a 401), then the request's `Origin`."""
def check_data_call(request: Request, config: GatekeeperConfig) -> Caller | Response {  # jac:ignore[W1036]
    caller = current_caller();
    if caller is None {
        return refusal(401, "UNAUTHORIZED", "Unauthorized");
    }
    if not from_own_page(request, config) {
        return refusal(403, "FORBIDDEN", "Forbidden");
    }
    return caller;
}

"""Whether `path` is the page or one of its static files: the only paths
forwarded to Jac's server. Nothing that climbs out of `/static/`; at the root,
only a built bundle's script or stylesheet (`/client.<hash>.js`, `/styles.css`) and the icons."""
def is_page_path(path: str) -> bool {
    if path == "/" or ROOT_ASSET.fullmatch(path) or ICON_ASSET.fullmatch(path) {
        return True;
    }
    return path.startswith("/static/") and ".." not in path and "//" not in path and "%" not in path;
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
    result = await anyio.to_thread.run_sync(lambda -> any { return call_function(caller, work, name=name); });
    if isinstance(result, WalkerError) {
        return (None, failed_call(result));
    }
    return (result, None);
}

"""`GET /auth/login`: send the browser to AuthKit, remembering where it came from."""
async def login(request: Request, config: GatekeeperConfig) -> Response {  # jac:ignore[W1036]
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
async def callback(request: Request, config: GatekeeperConfig) -> Response {  # jac:ignore[W1036]
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
async def logout(request: Request, config: GatekeeperConfig) -> Response {  # jac:ignore[W1036]
    if not from_own_page(request, config) {
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
async def session_check(config: GatekeeperConfig) -> Response {
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
def browser_sign_in_enabled(config: GatekeeperConfig) -> bool {
    return app_mode() == HOSTED and config.sessions is not None;
}

"""A route that answers 404 unless browser sign-in is on (hosted mode with a session provider)."""
def sign_in_route(handler: any, config: GatekeeperConfig) -> any {  # jac:ignore[W1036,W1037]
    async def route(request: Request) -> Response {  # jac:ignore[W1036]
        if not browser_sign_in_enabled(config) {
            return PlainTextResponse("Not Found", status_code=404);
        }
        return await handler(request, config);
    }
    return route;
}

"""The routes of browser sign-in and the session check: `/auth/login`,
`/auth/callback`, `/auth/logout` (each a 404 unless browser sign-in is on) and
`GET /me`."""
def sign_in_routes(config: GatekeeperConfig) -> list[Route] {
    async def me_route(_request: Request) -> Response {  # jac:ignore[W1036]
        return await session_check(config);
    }
    return [
        Route(LOGIN_PATH, sign_in_route(login, config), methods=["GET"]),
        Route(CALLBACK_PATH, sign_in_route(callback, config), methods=["GET"]),
        Route(LOGOUT_PATH, sign_in_route(logout, config), methods=["POST"]),
        Route(ME_PATH, me_route, methods=["GET"])
    ];
}

"""Whether `path` is one the MCP SDK's app answers."""
def is_mcp_path(path: str) -> bool {
    return any(path == p.rstrip("/") or path.startswith(p if p.endswith("/") else p + "/") for p in MCP_PREFIXES);
}

"""The value of the request header `wanted` (lower-case bytes), or None."""
def header_value(scope: dict[str, any], wanted: bytes) -> str | None {  # jac:ignore[W1037]
    for (name, value) in scope["headers"] {
        if name == wanted {
            return value.decode("latin-1");
        }
    }
    return None;
}

"""The bearer token a request carries, or None."""
def bearer_token(scope: dict[str, any]) -> str | None {  # jac:ignore[W1037]
    (kind, _, token) = (header_value(scope, b"authorization") or "").partition(" ");
    return token.strip() or None if kind.lower() == "bearer" else None;
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
async def credentials(scope: dict[str, any], config: GatekeeperConfig) -> Credentials {  # jac:ignore[W1037]
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
def refuse_anonymous(request: Request, config: GatekeeperConfig, ended: bool) -> Response {
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

"""The address a request came from: `X-Real-IP`, or "unknown" when it has none."""
def request_address(scope: dict[str, any]) -> str {  # jac:ignore[W1037]
    return (header_value(scope, b"x-real-ip") or "").strip() or UNKNOWN_ADDRESS;
}

"""The reply to a request over its limit: 429, `Retry-After` in seconds, a
one-line plain-text body."""
def too_many(pause: int) -> Response {
    unit = "second" if pause == 1 else "seconds";
    return PlainTextResponse(
        f"Too many requests, try again in {pause} {unit}", status_code=429, headers={"retry-after": str(pause)}
    );
}

"""Spend one request from `buckets` for `key`. When it is over its limit, answer
429 and say so (True)."""
async def refused_as_too_many(buckets: Buckets, key: str, scope: dict[str, any], receive: any, send: any) -> bool {  # jac:ignore[W1037]
    pause = buckets.take(key);
    if pause {
        await too_many(pause)(scope, receive, send);
    }
    return pause > 0;
}

"""The ASGI app, behind the rate limits and the sign-in check of hosted mode.
The health path answers anyone, uncounted. Discovery and the sign-in paths
answer anyone too, but count against the caller's address (30 a minute), as
does every request from no one, whether it is then answered or refused. Every
other request runs as the caller its credentials name
(`VERIFIED_SUB`, which `current_caller` reads) and
counts against that user (300 a minute, browser and connector together); a
session whose access token has expired is renewed and the renewed cookie goes
out with the response. A refusal is a 429, ahead of everything else. A request
from no one gets, for a page load or a page file, a redirect to sign in
(before anything is served: a page served with no caller would reload for ever
on its first 401), and for anything else a 401. If WorkOS cannot say whether a
session is good, the answer is 503 and the cookie stays. Local mode has no
check and no limit."""
def guarded(inner: any, config: GatekeeperConfig) -> any {  # jac:ignore[W1037]
    limits = config.limits or rate_limits();
    async def app(scope: dict[str, any], receive: any, send: any) {  # jac:ignore[W1037]
        if scope["type"] != "http" {
            await inner(scope, receive, send);
            return;
        }
        path = scope["path"];
        if app_mode() != HOSTED or path == HEALTH_PATH {
            await inner(scope, receive, send);
            return;
        }
        if path in AUTH_PATHS or (config.auth is not None and is_discovery_path(path)) {
            # Open to anyone, so counted against the address.
            if await refused_as_too_many(limits.addresses, request_address(scope), scope, receive, send) {
                return;
            }
            if config.auth is not None and is_discovery_path(path) {
                await discovery(config.auth)(scope, receive, send);
            } else {
                await inner(scope, receive, send);
            }
            return;
        }
        try {
            found = await credentials(scope, config);
        } except SessionCheckUnavailable {
            await PlainTextResponse("Sign-in is unavailable. Try again.", status_code=503, headers=NO_STORE)(scope, receive, send);
            return;
        }
        if found.caller is None {
            if await refused_as_too_many(limits.addresses, request_address(scope), scope, receive, send) {
                return;
            }
            await refuse_anonymous(Request(scope), config, found.ended)(scope, receive, send);
            return;
        }
        if await refused_as_too_many(limits.users, found.caller, scope, receive, send) {
            return;
        }
        token = VERIFIED_SUB.set(found.caller);
        try {
            if found.renewed is not None {
                send = send_with_cookie(send, cookie_header(SESSION_COOKIE, found.renewed, SESSION_MAX_AGE_S));
            }
            await inner(scope, receive, send);
        } finally {
            VERIFIED_SUB.reset(token);
        }
    }
    return app;
}
