"""Knowledge Pool - entry point.

Server endpoints come from `decks.jac`; the client UI from `frontend.jac`.
Importing `graph_runner` turns on strict permissions in this process too.
"""

import graph_runner;

import from decks {
    Deck,
    DeckView,
    FormatInfo,
    CreateDeck,
    ListDecks,
    GetDeck,
    EditDeck,
    DeleteDeck,
    ListOtherDecks,
    CopyOtherDeck,
    list_formats
}
import from collection { GetCollection, ChangeCollection, ImportCollection, ListUsers, GetOtherCollection }
import from collection_views { CollectionView, QuestListView }
import from quest_list { GetQuestList, GotQuest, GetOtherQuestList }
import from legality { Violation }
import from card_lines { CardLine }
import from cards {
    CardHit,
    CardSearch,
    CatalogInfo,
    search_cards,
    catalog_info,
    check_catalogue
}
import from deck_io { DeckExport, DeckImport, CreateDeckFromList, export_formats }

# Refuse to serve a catalogue built by older code: the error names the ingest command.
with entry {
    check_catalogue();
}


import from .frontend { app as ClientApp }

def:pub app -> JsxElement {
    return <ClientApp/>;
}
