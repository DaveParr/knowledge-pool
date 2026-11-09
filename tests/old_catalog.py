"""Turn a current test catalogue into one built by older code."""

import sqlite3

# `cards` as it was before `produced_mana` was added (#48).
_BEFORE_PRODUCED_MANA = [
    "oracle_id TEXT PRIMARY KEY",
    "name TEXT NOT NULL",
    "mana_cost TEXT NOT NULL",
    "mana_value REAL NOT NULL",
    "colour_identity TEXT NOT NULL",
    "types TEXT NOT NULL",
    "type_line TEXT NOT NULL",
    "text TEXT NOT NULL",
    "legalities TEXT NOT NULL",
]
# `cards` as it was before the card details columns were added (#70).
_BEFORE_CARD_DETAILS = _BEFORE_PRODUCED_MANA + ["produced_mana TEXT NOT NULL"]
# `cards` as it was before the commander fields were added (#50).
_BEFORE_COMMANDER = _BEFORE_CARD_DETAILS + [
    "power TEXT NOT NULL",
    "toughness TEXT NOT NULL",
    "loyalty TEXT NOT NULL",
    "defense TEXT NOT NULL",
    "keywords TEXT NOT NULL",
    "faces TEXT NOT NULL",
]


def _keep_only(con: sqlite3.Connection, columns: list[str]) -> None:
    """Rebuild `cards` with just `columns` (SQL column definitions).

    `ALTER TABLE ... DROP COLUMN` fails on some SQLite builds (CI's system
    SQLite gives "incomplete input") when the dropped column is last and is
    followed by a comment, so copy the kept columns into a new table instead.
    Rowids are kept so the `cards_fts` index still lines up.
    """
    names = ", ".join(c.split()[0] for c in columns)
    con.executescript(f"""
        CREATE TABLE cards_old ({", ".join(columns)});
        INSERT INTO cards_old (rowid, {names}) SELECT rowid, {names} FROM cards;
        DROP TABLE cards;
        ALTER TABLE cards_old RENAME TO cards;
        CREATE UNIQUE INDEX cards_name ON cards(name COLLATE NOCASE);
    """)


def drop_produced_mana(con: sqlite3.Connection) -> None:
    """Make `cards` as it was before `produced_mana` (#48), and so before the card details (#70)."""
    _keep_only(con, _BEFORE_PRODUCED_MANA)


def drop_card_details(con: sqlite3.Connection) -> None:
    """Make `cards` as it was before power, toughness, loyalty, defense, keywords and faces (#70)."""
    _keep_only(con, _BEFORE_CARD_DETAILS)


def drop_commander_fields(con: sqlite3.Connection) -> None:
    """Make `cards` as it was before leadership_skills and game_changer (#50)."""
    _keep_only(con, _BEFORE_COMMANDER)
