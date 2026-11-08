"""Turn a current test catalogue into one built by older code."""

import sqlite3

# `cards` as it was before `produced_mana` was added (#48).
_OLD_COLUMNS = "oracle_id, name, mana_cost, mana_value, colour_identity, types, type_line, text, legalities"


def drop_produced_mana(con: sqlite3.Connection) -> None:
    """Remove `cards.produced_mana` by rebuilding the table.

    `ALTER TABLE ... DROP COLUMN` fails on some SQLite builds (CI's system
    SQLite gives "incomplete input") when the dropped column is last and is
    followed by a comment, so copy the other columns into a new table instead.
    Rowids are kept so the `cards_fts` index still lines up.
    """
    con.executescript(f"""
        CREATE TABLE cards_old (
            oracle_id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            mana_cost TEXT NOT NULL,
            mana_value REAL NOT NULL,
            colour_identity TEXT NOT NULL,
            types TEXT NOT NULL,
            type_line TEXT NOT NULL,
            text TEXT NOT NULL,
            legalities TEXT NOT NULL
        );
        INSERT INTO cards_old (rowid, {_OLD_COLUMNS}) SELECT rowid, {_OLD_COLUMNS} FROM cards;
        DROP TABLE cards;
        ALTER TABLE cards_old RENAME TO cards;
        CREATE UNIQUE INDEX cards_name ON cards(name COLLATE NOCASE);
    """)
