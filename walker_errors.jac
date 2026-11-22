"""Why a walker failed. A walker that cannot do what it was asked reports one
WalkerError and nothing else; on success it reports as before. Web and MCP
callers both read the reason from here instead of guessing it from an empty
reports list."""

"""A failed walker's only report: a stable `code` callers can branch on, and a
`message` to show the user as is.

Codes: no-such-deck (no deck has that id), not-your-deck (a change to
another user's deck; the message points to copying), blank-name, unknown-format (a play format such as
standard), unknown-list-format (a deck list format such as moxfield),
no-export / no-import (the list format cannot go that way), refused-change
(a holdings change was refused; the message says why). The MCP tools add no-such-card (get_card) and card-search-failed (the catalogue
could not search). The runner adds two
of its own (`graph_runner.jac`): try-again (the call kept meeting another
writer and was rolled back) and internal-error (Jac refused a write the app
had allowed: an app fault, rolled back and logged). The web page adds `refused` (`session_bar.jac`) for a call
the front door refused, such as a 429, with the line to show."""
obj WalkerError {
    has code: str,
        message: str;
}
