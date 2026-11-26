"""My quest list: every card the signed-in user's decks need that their collection
does not have, with the decks that need it; mark copies got, and export it as
text. Its own view, apart from the decks and the collection, so a redesign can
place it anywhere (`onBack` returns to the Decks page)."""

import from .walker_failure { failureMessage }
import from .quest_lines { QuestLines }

import from quest_list { GetQuestList, GotQuest }
import from collection_views { QuestListView }
import from walker_errors { WalkerError }

def:pub QuestListPage(onBack: Callable[[], None]) -> JsxElement {
    has view: QuestListView | None = None,
        error: str = "",
        exportText: str = "",
        exportOpen: bool = False;

    can with entry {
        load();
    }

    async def load {
        result = root spawn GetQuestList(export=True);
        show(result.reports);
    }

    def show(reports: list[QuestListView | WalkerError]) {
        why = failureMessage(reports);
        error = why;
        if not why {
            view = reports[0] as QuestListView;
            exportText = view.text;
        }
    }

    async def got(oracleId: str, count: int) {
        result = root spawn GotQuest(oracle_id=oracleId, count=count);
        why = failureMessage(result.reports);
        if why {
            error = why;
            return;
        }
        load();
    }

    lines = view.lines if view is not None else [];

    return
        <main className="page narrow">
            <p>
                <a href="#" onClick={lambda (e: MouseEvent) { e.preventDefault(); onBack(); }}>← Decks</a>
            </p>
            <h1>My quest list</h1>
            <p className="fe-note">Every card your decks need that your collection does not have. It works itself out from your decks and collection.</p>
            {<p role="alert" className="error">{error}</p> if error else None}
            {<p className="empty">Nothing left to get.</p> if view is not None and not lines and not error else None}
            {<QuestLines
                lines={lines}
                label="My quest list"
                onGot={got}
            /> if lines else None}
            {<p>
                <button onClick={lambda (_e: MouseEvent) { exportOpen = not exportOpen; }}>Export as text</button>
            </p> if lines else None}
            {<div className="ql-export">
                <pre aria-label="Quest list text">{exportText}</pre>
            </div> if exportOpen and lines else None}
        </main>;
}
