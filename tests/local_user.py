"""The local user's decks, read in process through the runner (`graph_runner.jac`).

The MCP server and the seed script run every call as the local user. Jac's
own server runs the web page's calls as the guest, so a test reads the local
user's decks here, not over the web app's REST API.
"""

import sys

from jaclang.runtime.builtin import jid
from jaclang.testing.testing import JacTestClient


def local_user_decks(base_path) -> list:
    """Every deck the local user owns, as `DeckView`s, oldest first, from the
    database `JAC_DB_URL` names."""
    client = JacTestClient.from_file("main.jac", base_path=str(base_path))
    try:
        # The client's first request sets Jac up on that database in this process.
        assert client.get("/healthz").status_code == 200
        # The modules the app loaded (`main.jac` imports both), not fresh
        # copies: a second `decks` would have a `Deck` class the app's nodes
        # are not instances of.
        app = sys.modules[client._server.module_name]
        runner = app.graph_runner
        listed = runner.run_walker(runner.LOCAL_USER, app.ListDecks()).reports[0]
        return [runner.run_walker(runner.LOCAL_USER, app.GetDeck(deck_id=jid(d))).reports[0] for d in listed]
    finally:
        client.close()
