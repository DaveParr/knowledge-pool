"""Knowledge Pool - entry point.

Server endpoints come from `decks.sv.jac`; the client UI from `frontend.cl.jac`.
"""

import from decks {
    Deck, DeckCard, DeckView, CreateDeck, ListDecks, GetDeck, AddCard, SetCardCount, RemoveCard
}
import from cards { CardHit, CatalogInfo, search_cards, catalog_info }

cl {
    import from .frontend { app as ClientApp }

    def:pub app -> JsxElement {
        return <ClientApp/>;
    }
}
