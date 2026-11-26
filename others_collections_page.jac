"""Other users' collections: the users the signed-in user can look at, and one
user's collection, read-only. Its own view, apart from "My collection", so a
redesign can place it anywhere (`onBack` returns to the Decks page). It has no
control that changes anything."""

import from .walker_failure { failureMessage }

import from collection { ListUsers, GetOtherCollection }
import from collection_views { CollectionView, UserSummary }
import from walker_errors { WalkerError }

def:pub OthersCollectionsPage(onBack: Callable[[], None]) -> JsxElement {
    has users: list[UserSummary] = [],
        loaded: bool = False,
        error: str = "",
        openHandle: str = "",
        openName: str = "",
        view: CollectionView | None = None;

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
        result = root spawn GetOtherCollection(handle=handle);
        why = failureMessage(result.reports);
        error = why;
        if not why {
            openHandle = handle;
            openName = name;
            view = result.reports[0] as CollectionView;
        }
    }

    def closeUser {
        error = "";
        openHandle = "";
        openName = "";
        view = None;
    }

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
            <h1>{"Other users' collections" if not openHandle else openName + "'s collection"}</h1>
            <p className="fe-note">Read-only: only its owner can change a collection.</p>
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
                <h2>{"Cards (" + str(view.total if view is not None else 0) + ")"}</h2>
                {<p className="empty">Nothing in this collection yet.</p> if len(view.cards if view is not None else []) == 0 else None}
                <ul className="fe-decks" aria-label="Their collection">
                    {for line in (view.cards if view is not None else []) {
                        <li key={line.oracle_id} className="fe-deck">
                            <span>{line.name}</span>
                            <span className="pill">{"× " + str(line.count)}</span>
                        </li>
                    }}
                </ul>
                <h2>History</h2>
                {<p className="empty">No changes yet.</p> if len(view.history if view is not None else []) == 0 else None}
                <ul aria-label="Their collection history">
                    {for note in (view.history[::-1] if view is not None else []) {
                        <li key={note.at + note.oracle_id}>
                            {note.name + ": " + str(note.before) + " → " + str(note.after) + " (" + note.reason + ")"}
                        </li>
                    }}
                </ul>
            </div> if view is not None else None}
        </main>;
}
