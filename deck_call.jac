"""The deck-call endpoint: the web page's deck calls, `POST /walker/<name>` and
`POST /function/<name>` (ADR 0004).

Each takes the `Caller` the gatekeeper (`gatekeeper.jac`) yielded for the
request and runs the call as them through `perform` (walkers, from the deck
operations table) or the runner's `call_function` (the few `FUNCTIONS`), and
answers in Jac's own envelope (`data.reports` for a walker, `data.result` for a
function), serialised with Jac's own serialiser in API mode. It does no sign-in
work: no credential, session, `Origin` or rate-limit check happens here.

The walkers and functions the page calls are `:protect` (the page does not
compile with them plain) and never `:pub`; each walker must be a page-callable
entry of the deck operations table (`deck_operations.jac`, which derives
`WALKERS`) and each function must be in `FUNCTIONS` below. Jac's server refuses a
call to them without a Jac token, and no Jac token is ever issued.
"""

import inspect;
import json;
import anyio;
import from starlette.requests { Request }
import from starlette.responses { Response, JSONResponse }
import from graph_runner { call_function }
import from deck_operations { perform, page_walkers }
import from gatekeeper { Caller }
import from replies { refusal, envelope, failed_call }
import from decks { list_formats }
import from walker_errors { WalkerError }
import from deck_io { export_formats }
import from cards { search_cards }

# The walkers the page may call: the deck operations table's page-callable entries.
glob WALKERS: dict[str, any] = page_walkers(),  # jac:ignore[W1037]
     FUNCTIONS: dict[str, any] = {"list_formats": list_formats, "export_formats": export_formats, "search_cards": search_cards};  # jac:ignore[W1037]

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
def fields_fit(target: any, fields: dict[str, any]) -> bool {  # jac:ignore[W1037]
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

"""What a call names and carries: the entry of `table` the path's name picks and
the request's fields, or the refusal to answer with (404 for a name not in the
table, 422 with `misfit` for fields that do not fit it)."""
async def resolve_call(request: Request, table: dict[str, any], misfit: str) -> tuple[any, dict[str, any]] | Response {  # jac:ignore[W1036,W1037]
    target = table.get(str(request.path_params["name"]));
    if target is None {
        return refusal(404, "NOT_FOUND", "Not Found");
    }
    fields = await read_fields(request);
    if fields is None or not fields_fit(target, fields) {
        return refusal(422, "INVALID_REQUEST", misfit);
    }
    return (target, fields);
}

"""`POST /walker/<name>`: run the walker as `caller`, answer in Jac's envelope."""
async def walker_call(caller: Caller, request: Request) -> Response {  # jac:ignore[W1036]
    resolved = await resolve_call(request, WALKERS, "The call's fields do not fit this walker.");
    if isinstance(resolved, Response) {
        return resolved;
    }
    (cls, fields) = resolved;
    call = cls(**fields);
    finished = await anyio.to_thread.run_sync(lambda -> any { return perform(caller.user_id, call); });
    return JSONResponse(envelope(finished, finished.reports));
}

"""`POST /function/<name>`: call the function as `caller`, answer in Jac's envelope."""
async def function_call(caller: Caller, request: Request) -> Response {  # jac:ignore[W1036]
    resolved = await resolve_call(request, FUNCTIONS, "The call's arguments do not fit this function.");
    if isinstance(resolved, Response) {
        return resolved;
    }
    (fn, args) = resolved;
    result = await anyio.to_thread.run_sync(
        lambda -> any { return call_function(caller.user_id, lambda -> any { return fn(**args); }, name=fn.__name__); }
    );
    if isinstance(result, WalkerError) {
        return failed_call(result);
    }
    return JSONResponse(envelope(result, []));
}
