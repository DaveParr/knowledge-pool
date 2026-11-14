"""Test rig for #104: the MCP process as the front door.

It answers the web page's deck calls (`POST /walker/<name>`, `POST /function/<name>`)
itself, in process, as the signed-in user, and forwards only the page and its
static files to Jac's server on 127.0.0.1. Sign-in is a stand-in: a cookie set
by `/test-sign-in?user=<name>`. Not the build.

Run in the scratch port (see ../front-door-deck-calls-test.md), with Jac's
server already on 18761:

    KP_WEB=0 jac run --no-serve front_door.jac
"""

import copy;
import json;
import os;
import sys;
import time;
import anyio;
import httpx2;
import from starlette.requests { Request }
import from starlette.responses { Response, JSONResponse, RedirectResponse, PlainTextResponse }
import from mcp.server.streamable_http { TransportSecuritySettings }
import from jaclang { JacRuntime as Jac }
import from jaclang.runtime.context { ExecutionContext }
import from jaclang.server.session { transient_db_error }
import from jaclang.data.serializer { Serializer }
import from mcp_server { server }
import from shared_graph { APP_DIR, LOCK }
import from decks { CreateDeck, ListDecks, GetDeck, SetDeckFormat, AddCard, SetCardCount, RemoveCard, list_formats }
import from deck_io { DeckExport, DeckImport, CreateDeckFromList }
import from cards { search_cards, catalog_info, find_card, resolve_names }

glob JAC_URL: str = os.environ.get("KP_JAC_URL", "http://127.0.0.1:18761"),
     OWN_ORIGIN: str = os.environ.get("KP_OWN_ORIGIN", "http://127.0.0.1:18762"),
     COOKIE: str = "kp_test_session",
     WALKERS: dict[str, any] = {
         "CreateDeck": CreateDeck, "ListDecks": ListDecks, "GetDeck": GetDeck, "SetDeckFormat": SetDeckFormat,
         "AddCard": AddCard, "SetCardCount": SetCardCount, "RemoveCard": RemoveCard, "DeckExport": DeckExport,
         "DeckImport": DeckImport, "CreateDeckFromList": CreateDeckFromList
     },
     FUNCS: dict[str, any] = {
         "list_formats": list_formats, "search_cards": search_cards, "catalog_info": catalog_info,
         "find_card": find_card, "resolve_names": resolve_names
     },
     ROOTS: dict[str, str] = {};

"""One line per request the front door sees, on stderr: what the client sent and what it got."""
def note(request: Request, outcome: str) -> None {
    h = request.headers;
    sys.stderr.write(
        f"FD {request.method} {request.url.path} -> {outcome} | auth={'yes' if h.get('authorization') else 'no'} "
        + f"origin={h.get('origin')} cookie={'yes' if request.cookies.get(COOKIE) else 'no'} "
        + f"x-jac-endpoint={h.get('x-jac-endpoint')} accept={h.get('accept')}\n"
    );
}

"""The root id of the Jac user with this name, created on first use."""
def user_root_id(user: str) -> str {
    if user not in ROOTS {
        um = Jac.get_user_manager(base_path=APP_DIR);
        um.ensure_internal_user(user, "__no_password__");
        ROOTS[user] = str(um.get_root_id(user));
    }
    return ROOTS[user];
}

"""Run `work` in a request context on this user's root and commit. Rolls back
and re-runs on a write conflict, as the external Postgres test found is needed."""
def run_as(user: str, work: any) -> any {
    with LOCK {
        attempt = 0;
        while True {
            attempt += 1;
            ctx = ExecutionContext(_parent=Jac.get_context());
            ctx.set_user_root(user_root_id(user));
            token = Jac.push_request_context(ctx);
            try {
                done = work(ctx);
                Jac.commit();
                return done;
            } except Exception as e {
                ctx.mem.abort();
                if attempt >= 8 or not (transient_db_error(e) or type(e).__name__ == "WriteConflict") {
                    raise;
                }
                sys.stderr.write(f"run_as: {type(e).__name__}, replay {attempt}\n");
                time.sleep(0.02 * attempt);
            } finally {
                Jac.reset_request_context(token);
            }
        }
    }
}

"""The signed-in user's name from the stand-in session cookie, or ""."""
def signed_in(request: Request) -> str {
    return request.cookies.get(COOKIE) or "";
}

"""Why a browser data call is refused before it runs, or None."""
def refusal(request: Request) -> Response | None {
    if not signed_in(request) {
        note(request, "401 no session");
        return JSONResponse(
            {"ok": False, "type": "error", "data": None, "error": {"code": "UNAUTHORIZED", "message": "Unauthorized"}},
            status_code=401
        );
    }
    if request.headers.get("origin") != OWN_ORIGIN {
        note(request, "403 wrong origin");
        return JSONResponse(
            {"ok": False, "type": "error", "data": None, "error": {"code": "FORBIDDEN", "message": "Wrong origin"}},
            status_code=403
        );
    }
    return None;
}

"""Jac's own reply envelope for a walker or function call."""
def envelope(result: any, reports: any) -> dict[str, any] {
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

@server.custom_route("/walker/{name}", methods=["POST"])
async def walker_call(request: Request) -> Response {
    refused = refusal(request);
    if refused is not None {
        return refused;
    }
    name = str(request.path_params["name"]);
    cls = WALKERS.get(name);
    if cls is None {
        note(request, "404 no such walker");
        return JSONResponse({"detail": "Not Found"}, status_code=404);
    }
    fields = json.loads((await request.body()) or b"{}");
    try {
        w = cls(**fields);
    } except TypeError as e {
        note(request, "422");
        return JSONResponse({"detail": str(e)}, status_code=422);
    }
    done = run_as(signed_in(request), lambda (ctx: any) -> any { return Jac.spawn(ctx.get_root(), copy.deepcopy(w)); });
    note(request, f"200 walker as {signed_in(request)}");
    return JSONResponse(envelope(done, done.reports));
}

@server.custom_route("/function/{name}", methods=["POST"])
async def function_call(request: Request) -> Response {
    refused = refusal(request);
    if refused is not None {
        return refused;
    }
    name = str(request.path_params["name"]);
    fn = FUNCS.get(name);
    if fn is None {
        note(request, "404 no such function");
        return JSONResponse({"detail": "Not Found"}, status_code=404);
    }
    args = json.loads((await request.body()) or b"{}");
    result = run_as(signed_in(request), lambda (ctx: any) -> any { return fn(**args); });
    note(request, f"200 function as {signed_in(request)}");
    return JSONResponse(envelope(result, []));
}

@server.custom_route("/test-sign-in", methods=["GET"])
async def test_sign_in(request: Request) -> Response {
    user = request.query_params.get("user") or "";
    resp = RedirectResponse("/", status_code=302);
    if user {
        resp.set_cookie(COOKIE, user, httponly=True, samesite="lax");
    } else {
        resp.delete_cookie(COOKIE);
    }
    note(request, f"302 signed in as {user or 'nobody'}");
    return resp;
}

@server.custom_route("/health", methods=["GET"])
async def health(request: Request) -> Response {
    return PlainTextResponse("ok");
}

"""The page and its static files go to Jac's server; everything else is 404 here."""
@server.custom_route("/{path:path}", methods=["GET", "POST", "PUT", "DELETE", "PATCH"])
async def everything_else(request: Request) -> Response {
    path = request.url.path;
    allowed = request.method == "GET" and (path == "/" or path.startswith("/static/"));
    if not allowed {
        note(request, "404 not on the allow-list");
        return JSONResponse({"detail": "Not Found"}, status_code=404);
    }
    if not signed_in(request) {
        note(request, "401 page refused, not signed in");
        return PlainTextResponse("Not signed in. Test rig: open /test-sign-in?user=alice", status_code=401);
    }
    http: any = httpx2;
    upstream: any = None;
    async with http.AsyncClient() as client {
        upstream = await client.get(JAC_URL + path, params=dict(request.query_params));
    }
    note(request, f"{upstream.status_code} forwarded to Jac");
    keep = {k: v for (k, v) in upstream.headers.items() if k.lower() in ["content-type", "cache-control", "etag"]};
    return Response(content=upstream.content, status_code=upstream.status_code, headers=keep);
}

with entry:__main__ {
    os.chdir(APP_DIR);
    port = int(os.environ.get("KP_HTTP_PORT", "18762"));
    security = TransportSecuritySettings(
        allowed_hosts=[f"127.0.0.1:{port}", f"localhost:{port}"], allowed_origins=[OWN_ORIGIN]
    );
    run_any: any = anyio.run;
    run_any(lambda -> any { return server.run_streamable_http_async(host="127.0.0.1", port=port, transport_security=security); });
}
