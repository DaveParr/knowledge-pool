"""Knowledge Pool - entry point.

Server endpoints come from `decks.sv.jac`; the client UI from `frontend.cl.jac`.
"""

import from decks { Deck, CreateDeck, ListDecks }

cl {
    import from .frontend { app as ClientApp }

    def:pub app -> JsxElement {
        return <ClientApp/>;
    }
}
