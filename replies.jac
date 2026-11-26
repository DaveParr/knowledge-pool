"""Jac's reply envelope, as the front door answers in it: a refusal with the
HTTP status Jac's server would use, a finished call, and a call the runner could
not finish. Shared by the gatekeeper (`gatekeeper.jac`) and the deck-call
endpoint (`deck_call.jac`)."""

import from starlette.responses { Response, JSONResponse }
import from jaclang.data.serializer { Serializer }
import from walker_errors { WalkerError }

# The runner errors that are worth asking again, answered 503.
glob UNAVAILABLE_CODES: list[str] = ["try-again", "busy"];

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

"""A call the runner could not finish, as Jac's error envelope: the one place
a walker error becomes a failure reply here. (A walker's own failure is a report
in an ordinary reply; the page reads this one as a refusal, `refusedAsReport`.)"""
def failed_call(error: WalkerError) -> Response {
    status = 503 if error.code in UNAVAILABLE_CODES else 500;
    return refusal(status, error.code.upper(), error.message);
}
