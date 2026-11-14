"""Knowledge Pool - entry point.

Server endpoints come from `decks.jac`; the client UI from `frontend.jac`.
Importing `runner` turns on strict permissions in this process too. Until the
front door runs the page's calls (#129), the page's `:pub` walkers run on Jac's
own server as the guest, so its decks are not the local user's.
"""

import runner;

import from decks {
    Deck,
    DeckView,
    FormatInfo,
    CreateDeck,
    ListDecks,
    GetDeck,
    SetDeckFormat,
    AddCard,
    SetCardCount,
    RemoveCard,
    list_formats
}
import from legality { Violation }
import from card_lines { CardLine }
import from cards {
    CardHit,
    CardSearch,
    CatalogInfo,
    search_cards,
    catalog_info,
    check_catalogue,
    RefreshCards
}
import from deck_io { DeckExport, DeckImport, CreateDeckFromList }

# Refuse to serve a catalogue built by older code: the error names the ingest command.
with entry {
    check_catalogue();
}


import from .frontend { app as ClientApp }

def:pub app -> JsxElement {
    return <ClientApp/>;
}
