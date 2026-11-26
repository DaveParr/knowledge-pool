"""The front door: the one listener of the app (ADR 0004).

The MCP process answers every request. Three modules sit behind it: the
gatekeeper (`gatekeeper.jac`) checks credentials, runs browser sign-in and applies
the rate limits, yielding the `Caller` of every request it lets through; the
deck-call endpoint (`deck_call.jac`) runs the web page's deck calls as that
caller; the upstream child (`upstream_child.jac`) starts, stops and watches Jac's
server. This module puts them together: it routes a request to one of them, to the
MCP SDK's app, or to Jac's server.

Jac's own server runs beside it as a child on 127.0.0.1 and only hands out the web
page and its static files; the front door forwards those two kinds of path and no
others. The static files are under `/static/`, or, for the bundle `jac build --as
client` writes (the hosted image), a script or stylesheet at the root, plus the icons
under `/icons/<set>/` (the page head's favicon and apple-touch icon). Every other
path answers 404, so Jac's docs, graph, admin, listing, `/user/*` and `/sso/*`
endpoints are never reachable from outside. It never forwards an `Authorization`
header or a path under `/walker/`, `/function/`, `/user/` or `/sso/` (ADR 0004).

The web page's deck calls, `POST /walker/<name>` and `POST /function/<name>`, are
not forwarded either: the deck-call endpoint answers them, for the caller the
gatekeeper found (`check_data_call`: no caller is a 401, then the request's
`Origin` is checked).

A health path answers a bare "ok" without touching Jac, for any host.

The same ASGI app serves `/mcp` (and anything under `/.well-known/`) by
handing it to the MCP SDK's app.
"""

import httpx2;
import from starlette.applications { Starlette }
import from starlette.requests { Request }
import from starlette.responses { Response, PlainTextResponse }
import from starlette.routing { Route }
import from gatekeeper { GatekeeperConfig, HEALTH_PATH, check_data_call, guarded, is_mcp_path, is_page_path, sign_in_routes }
import from deck_call { walker_call, function_call }

# The request headers worth passing to Jac's server for the page and its files.
glob FORWARDED_REQUEST_HEADERS: list[str] = ["accept", "if-none-match", "if-modified-since"],
     FORWARDED_RESPONSE_HEADERS: list[str] = ["content-type", "cache-control", "etag", "last-modified"];

"""What a front door needs to know: where Jac's server listens (`upstream`),
the HTTP client that reaches it (a test passes one on a stub) and the
gatekeeper's configuration (`gate`)."""
obj FrontDoorConfig {
    has upstream: str,
        gate: GatekeeperConfig,
        client: any = None;  # jac:ignore[W1037]
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
async def forward_or_not_found(request: Request, config: FrontDoorConfig) -> Response {  # jac:ignore[W1036]
    if request.method in ["GET", "HEAD"] and is_page_path(request.url.path) {
        return await forward_page(request, config);
    }
    return PlainTextResponse("Not Found", status_code=404);
}

"""The health path: a bare "ok" for any host."""
async def health(_request: Request) -> Response {  # jac:ignore[W1036]
    return PlainTextResponse("ok");
}

"""A route for a deck call: the gatekeeper's check first, then `handler` as the caller it found."""
def deck_call_route(handler: any, config: FrontDoorConfig) -> any {  # jac:ignore[W1036,W1037]
    async def route(request: Request) -> Response {  # jac:ignore[W1036]
        caller = check_data_call(request, config.gate);
        if isinstance(caller, Response) {
            return caller;
        }
        return await handler(caller, request);
    }
    return route;
}

"""The front door's own routes, apart from the MCP SDK's."""
def web_app(config: FrontDoorConfig) -> Starlette {
    async def other_route(request: Request) -> Response {  # jac:ignore[W1036]
        return await forward_or_not_found(request, config);
    }
    return Starlette(
        routes=[
            Route(HEALTH_PATH, health, methods=["GET", "HEAD"]),
            *sign_in_routes(config.gate),
            Route("/walker/{name}", deck_call_route(walker_call, config), methods=["POST"]),
            Route("/function/{name}", deck_call_route(function_call, config), methods=["POST"]),
            Route("/{path:path}", other_route, methods=["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"])
        ]
    );
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
    return guarded(app, config.gate);
}
