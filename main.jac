"""Knowledge Pool - entry point.

Server endpoints come from `decks.sv.jac`; the client UI from `frontend.cl.jac`.
"""

import from decks {
    Deck, DeckView, FormatInfo, CreateDeck, ListDecks, GetDeck, SetDeckFormat,
    AddCard, SetCardCount, RemoveCard, list_formats
}
import from legality { Violation }
import from card_lines { CardLine }
import from cards { CardHit, CatalogInfo, search_cards, catalog_info }
import from deck_io { DeckExport, DeckImport, CreateDeckFromList }

cl {
    import from .frontend { app as ClientApp }

    def:pub app -> JsxElement {
        return <ClientApp/>;
    }
}
