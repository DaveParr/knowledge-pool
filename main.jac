"""Knowledge Pool - entry point.

Server endpoints come from `decks.sv.jac`; the client UI from `frontend.cl.jac`.
"""

import from decks {
    Deck, DeckView, FormatInfo, CreateDeck, ListDecks, GetDeck, SetDeckFormat,
    AddCard, SetCardCount, RemoveCard, list_formats
}
import from legality { Violation }
import from card_lines { CardLine }
import from cards { CardHit, CardSearch, CatalogInfo, search_cards, catalog_info, check_catalogue, RefreshCards }
import from deck_io { DeckExport, DeckImport, CreateDeckFromList }

# Refuse to serve a catalogue built by older code: the error names the ingest command.
with entry {
    check_catalogue();
}

cl {
    import from .frontend { app as ClientApp }

    def:pub app -> JsxElement {
        return <ClientApp/>;
    }
}
