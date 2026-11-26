"""The lines of a quest list: each card, how many copies are still needed and the
decks that need it. A "got" control appears on each line only when the page
gives an `onGot` (a user's own quest list); another user's has none."""

import from collection_views { QuestLine }

"""One line: the card, `× count`, each deck with how many it needs and, on
the user's own quest list, how many copies they got."""
def QuestRow(line: QuestLine, onGot: Callable[[str, int], None] | None) -> JsxElement {
    has copies: str = "1";

    def got {
        text = copies.strip();
        if text.isdigit() and int(text) > 0 {
            onGot(line.oracle_id, int(text));
        }
    }

    return
        <li className="fe-deck">
            <span>{line.name}</span>
            <span className="pill">{"× " + str(line.count)}</span>
            <span className="ql-decks">
                {", ".join([d.name + " × " + str(d.count) for d in line.decks])}
            </span>
            {<span>
                <input
                    type="number"
                    min="1"
                    aria-label={"Copies of " + line.name + " got"}
                    value={copies}
                    onChange={lambda (e: ChangeEvent) { copies = e.target.value; }}
                />
                <button aria-label={"Got " + line.name} onClick={lambda (_e: MouseEvent) { got(); }}>Got</button>
            </span> if onGot is not None else None}
        </li>;
}

def:pub QuestLines(lines: list[QuestLine], label: str, onGot: Callable[[str, int], None] | None) -> JsxElement {
    return
        <ul className="fe-decks" aria-label={label}>
            {for line in lines {
                <QuestRow key={line.oracle_id} line={line} onGot={onGot}/>
            }}
        </ul>;
}
