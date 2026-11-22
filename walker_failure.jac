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

"""The message of the WalkerError a failed call reported, or "" if it succeeded.
This is the one way the page reads a failure. A walker's reports come in as they
are; a function call has no reports, so pass its result as `[result]`: a call that
failed answers with the WalkerError as its result (`refusedAsReport`,
`session_bar.jac`), and no result of a call that succeeded has a `code`."""
def:pub failureMessage(reports: Sequence[object]) -> str {
    if len(reports) == 0 or reports[0] is None {
        return "";
    }
    first = reports[0] as WalkerError;
    return first.message if first.code else "";
}
