"""Other users' quest lists: the users the signed-in user can look at, and one
user's quest list, read-only. Its own view, apart from "My quest list" and from
the other users' collections, so a redesign can place it anywhere (`onBack`
returns to the Decks page). It has no control that changes anything."""

import from .walker_failure { failureMessage }
import from .quest_lines { QuestLines }

import from collection { ListUsers }
import from quest_list { GetOtherQuestList }
import from collection_views { QuestListView, UserSummary }

def:pub OthersQuestListsPage(onBack: Callable[[], None]) -> JsxElement {
    has users: list[UserSummary] = [],
        loaded: bool = False,
        error: str = "",
        openHandle: str = "",
        openName: str = "",
        view: QuestListView | None = None;

    can with entry {
        loadUsers();
    }

    async def loadUsers {
        result = root spawn ListUsers();
        why = failureMessage(result.reports);
        error = why;
        if not why {
            users = result.reports[0] as list[UserSummary];
        }
        loaded = True;
    }

    async def openUser(handle: str, name: str) {
        result = root spawn GetOtherQuestList(handle=handle, export=True);
        why = failureMessage(result.reports);
        error = why;
        if not why {
            openHandle = handle;
            openName = name;
            view = result.reports[0] as QuestListView;
        }
    }

    def closeUser {
        error = "";
        openHandle = "";
        openName = "";
        view = None;
    }

    lines = view.lines if view is not None else [];

    return
        <main className="page narrow">
            <p>
                <a
                    href="#"
                    onClick={lambda (e: MouseEvent) { e.preventDefault(); onBack() if not openHandle else closeUser(); }}
                >
                    {"← Decks" if not openHandle else "← Other users"}
                </a>
            </p>
            <h1>{"Other users' quest lists" if not openHandle else openName + "'s quest list"}</h1>
            <p className="fe-note">Read-only: only its owner can get cards from it.</p>
            {<p role="alert" className="error">{error}</p> if error else None}
            {<p className="empty">No other users yet.</p> if not openHandle and loaded and not users and not error else None}
            {<ul className="fe-decks" aria-label="Other users">
                {for u in users {
                    <li key={u.handle} className="fe-deck">
                        <a href="#" onClick={lambda (e: MouseEvent) { e.preventDefault(); openUser(u.handle, u.name); }}>{u.name}</a>
                    </li>
                }}
            </ul> if not openHandle else None}
            {<div>
                {<p className="empty">They need nothing more.</p> if not lines else None}
                <QuestLines lines={lines} label="Their quest list" onGot={None}/>
                {<pre className="ql-text" aria-label="Their quest list text">{view.text}</pre> if view is not None and view.text else None}
            </div> if view is not None else None}
        </main>;
}
