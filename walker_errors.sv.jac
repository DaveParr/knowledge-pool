"""Why a walker failed. A walker that cannot do what it was asked reports one
WalkerError and nothing else; on success it reports as before. Web and MCP
callers both read the reason from here instead of guessing it from an empty
reports list."""

"""A failed walker's only report: a stable `code` callers can branch on, and a
`message` to show the user as is.

Codes: no-such-deck, blank-name, unknown-format (a play format such as
standard), unknown-list-format (a deck list format such as moxfield),
no-export / no-import (the list format cannot go that way), refused-change
(a holdings change was refused; the message says why)."""
obj WalkerError {
    has code: str,
        message: str;
}
