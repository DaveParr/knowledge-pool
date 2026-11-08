"""Reading a walker's failure on the client.

A walker that fails reports one WalkerError (see walker_errors.sv.jac) and
nothing else. Reports reach the client as plain JSON, so isinstance cannot
tell a WalkerError apart; its `code` field can, since no success report has one."""

sv import from walker_errors { WalkerError }

"""The message of the WalkerError a failed walker reported, or "" if it succeeded."""
def:pub failureMessage(reports: Sequence[object]) -> str {
    if len(reports) == 0 {
        return "";
    }
    first = reports[0] as WalkerError;
    return first.message if first.code else "";
}
