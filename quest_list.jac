"""The quest list: every card a user's decks need that their collection does not
have, worked out on read and never stored (CONTEXT.md, Quest list)."""

import from decks { Deck, card_lines }
import from card_lines { played_needs }
import from deckformats { ExportEntry, ExportDeck, get_format }
import from collection { find_collection, my_collection, change_count, copies }
import from collection_views { QuestDeck, UserAction, QuestLine, QuestListView, MODE_ADD, REFUSED_CHANGE }
import from walker_errors { WalkerError }

"""The reason a "got" from the quest list is logged with."""
glob REASON_GOT: str = "got from the quest list";

"""The quest list of the root this runs on: per oracle card, the largest count
any one of the user's decks needs across `PLAYED_ZONES`, minus their
collection's count, for the cards where that is above zero."""
def quest_list_view -> QuestListView {
    coll = find_collection();
    names: dict[str, str] = {};
    needs: dict[str, list[QuestDeck]] = {};
    for deck in [root-->[?:Deck]] {
        (per_card, deck_names) = played_needs(card_lines(deck));
        names.update(deck_names);
        for (oid, count) in per_card.items() {
            needs.setdefault(oid, []).append(QuestDeck(deck_id=jid(deck), name=deck.name, count=count));
        }
    }
    lines: list[QuestLine] = [];
    for (oid, decks) in needs.items() {
        have = copies(coll, oid) if coll is not None else 0;
        short = max([d.count for d in decks]) - have;
        if short > 0 {
            lines.append(QuestLine(oracle_id=oid, name=names[oid], count=short, decks=decks));
        }
    }
    lines.sort(key=lambda (l: QuestLine) { return l.name; });
    return QuestListView(lines=lines);
}

"""The quest list as a plain-text line list (`3 Lightning Bolt`), through the
same renderer as a deck's text export: each line is a card in the main zone."""
def quest_text(view: QuestListView) -> str {
    entries = [ExportEntry(oracle_id=l.oracle_id, name=l.name, count=l.count, zone="main") for l in view.lines];
    return get_format("text").render(ExportDeck(name="Quest list", format="", entries=entries));
}

"""The quest list of the root this runs on, with its text when `export` is set."""
def quest_list_reading(export: bool) -> QuestListView {
    view = quest_list_view();
    if export {
        view.text = quest_text(view);
    }
    return view;
}

"""Report the caller's quest list."""
walker:protect GetQuestList {
    has export: bool = False;
    has reports: list[QuestListView | WalkerError] = [];

    can show with Root entry {
        report quest_list_reading(self.export);
    }
}

"""Mark `count` copies of the card `oracle_id` as got from the quest list: the
collection's writer adds them, with a reason naming the quest list, and the
walker reports the quest list as it now stands. Getting fewer than needed
reduces the line rather than clearing it. A refused change (an unknown card, a
count that is not a whole number above zero) reports `refused-change` and
writes nothing."""
walker:protect GotQuest {
    has oracle_id: str,
        count: int,
        reports: list[QuestListView | WalkerError] = [];

    can got with Root entry {
        coll = my_collection();
        why = change_count(coll, self.oracle_id, self.count, MODE_ADD, REASON_GOT);
        if why {
            report WalkerError(code=REFUSED_CHANGE, message=f"Change refused: {why}");
            disengage;
        }
        if find_collection() is None {
            root ++> coll;
        }
        report quest_list_view();
    }
}

"""Report another user's quest list, by their handle, read-only."""
walker:protect GetOtherQuestList(UserAction) {
    has export: bool = False;
    has reports: list[QuestListView | WalkerError] = [];

    can show with Root entry {
        report quest_list_reading(self.export);
    }
}
