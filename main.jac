"""Knowledge Pool - entry point.

Server endpoints come from `decks.sv.jac`; the client UI from `frontend.cl.jac`.
"""

import from decks {
    Deck, DeckCard, DeckView, FormatInfo, CreateDeck, ListDecks, GetDeck, SetDeckFormat,
    AddCard, SetCardCount, RemoveCard, list_formats, AnalyzeDeck
}
import from legality { Violation }
import from cards { CardHit, CatalogInfo, search_cards, catalog_info }
import from deck_io { DeckExport, DeckImport, CreateDeckFromList }
import from catalog { store }

# Refuse to serve a catalogue built by older code: the error names the ingest command.
with entry {
    store.check_current();
}

cl {
    import from .frontend { app as ClientApp }

    def:pub app -> JsxElement {
        return <ClientApp/>;
    }
}
