# Collections count oracle cards, not printings

A collection holds a count per oracle card. Each count is stored as an `Owns` edge keyed by (card, printing), with the printing always blank for now, so printings can be added later as extra fields without remodelling the graph or migrating stored counts. A card's oracle-level total is a sum over its entries (today, the one entry).

## Why

Decks and legality are about oracle cards, so "do I have this card" is an oracle question. Printings, set, collector number, foil and condition are out of scope for the first collections; keying by (card, printing) now costs nothing and avoids a migration later.

## What adding printings would take

- A printing value on `Owns` edges, and the collection writer taking it (a blank printing stays "any printing").
- Reads that sum a card's entries for oracle-level counts (deck lines, missing cards, the quest list).
- Parsers and the import path carrying set and collector number, and a catalogue that knows them.
