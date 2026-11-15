"""The front door: the one listener of the app (ADR 0004).

The MCP process answers every request. Jac's own server runs beside it as a
child on 127.0.0.1 and only hands out the web page and its static files; the
front door forwards those two kinds of path and no others. Every other path
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

The same ASGI app serves `/mcp` (and anything under `/.well-known/`) by
handing it to the MCP SDK's app.
"""

import inspect;
import json;
import os;
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
import from starlette.responses { Response, JSONResponse, PlainTextResponse }
import from starlette.routing { Route }
import from jaclang.data.serializer { Serializer }
import from graph_runner { APP_DIR, request_caller, run_walker, call_function, CallFailed }
import from decks { CreateDeck, ListDecks, GetDeck, SetDeckFormat, AddCard, SetCardCount, RemoveCard, list_formats }
import from deck_io { DeckExport, DeckImport, CreateDeckFromList }
import from cards { search_cards }

glob HEALTH_PATH: str = "/healthz",
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
     UPSTREAM_BOOT_S: float = 120.0,
     STOPPING: list[bool] = [];

"""What a front door needs to know: where Jac's server listens (`upstream`),
the `Origin`s of its own page (the only ones a browser data call may carry),
and the HTTP client that reaches the upstream (a test passes one on a stub)."""
obj FrontDoorConfig {
    has upstream: str,
        origins: list[str],
        client: any = None;  # jac:ignore[W1037]
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
forwarded to Jac's server. Nothing that climbs out of `/static/`."""
def is_page_path(path: str) -> bool {
    if path == "/" {
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
    return Starlette(
        routes=[
            Route(HEALTH_PATH, health, methods=["GET", "HEAD"]),
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
