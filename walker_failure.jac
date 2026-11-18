"""Reading a walker's failure on the client.

A walker that fails reports one WalkerError (see walker_errors.jac) and
nothing else. Reports reach the client as plain JSON, so isinstance cannot
tell a WalkerError apart; its `code` field can, since no success report has one."""

import from walker_errors { WalkerError }

glob REFUSED_CODE: str = "refused",
     REFUSED_LINE: str = "The request was refused. Reload the page and try again.";

"""The one line to show for a call the front door answered with an error
status instead of a report: a 429's own plain-text body ("Too many requests,
try again in N seconds"), or the message of Jac's error envelope (`try-again`,
the internal error). Anything else gets a generic line."""
def:pub refusalLine(status: int, body: str) -> str {
    if status == 429 and body.strip() {
        return body.strip();
    }
    try {
        page: any = window;  # jac:ignore[W1037]
        parsed: any = page.JSON.parse(body);  # jac:ignore[W1037]
        error: any = parsed["error"];
        if error and error["message"] {
            return str(error["message"]);
        }
    } except Exception {
        return REFUSED_LINE;
    }
    return REFUSED_LINE;
}

"""The one line to show for a call that threw instead of answering (a function
call the front door refused): its status and the body it came back with."""
def:pub thrownLine(failure: any) -> str {  # jac:ignore[W1037]
    detail = str(failure.detail or "");
    marker = " failed: ";
    at = detail.find(marker);
    body: str = detail[at + len(marker):] if at >= 0 else detail;
    return refusalLine(int(failure.status or 0), body);
}

"""The message of the WalkerError a failed walker reported, or "" if it succeeded."""
def:pub failureMessage(reports: Sequence[object]) -> str {
    if len(reports) == 0 {
        return "";
    }
    first = reports[0] as WalkerError;
    return first.message if first.code else "";
}
