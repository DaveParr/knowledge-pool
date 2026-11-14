"""Seed this checkout's graph with one random MTGJSON precon per format.

    jac run --no-serve seed.jac                       # one precon each: standard, pioneer, modern, commander
    jac run --no-serve seed.jac --seed 42             # repeatable picks (the seed is printed every run)
    jac run --no-serve seed.jac --format modern       # only some formats (repeatable)
    jac run --no-serve seed.jac --from-dir DIR        # DeckList.json and deck files from DIR, no network

Picks come from MTGJSON's DeckList.json (catalog/precons.py maps each deck type
to a play format). For each format it tries up to 3 random precons and takes
the first that is legal in that format today, else the last one tried. A
precon whose name is already a deck in the graph is never picked again, so
each run adds new decks.

Decks are made by `CreateDeckFromList` on the shared guest root, the same
graph the web app and MCP server use; they may keep running. The card
catalogue must be built first (or KP_CATALOG pointed at one).
"""

import argparse;
import io;
import os;
import random;
import sys;
import from urllib.error { URLError }
import from contextlib { redirect_stdout }
import from datetime { date }
import from catalog.precons { DECK_TYPES, TRIES, DeckSource, Pick, candidates, format_rng, pick }
import from cards { check_catalogue, card_node }
import from card_lines { CardLine }
import from decks { Deck, ListDecks, GetDeck, DeckView, card_line }
import from deckformats.mtgjson { is_skipped_list_note }
import from deck_io { CreateDeckFromList, NewDeckResult, resolve_list }
import from legality { Violation, check_lines, format_node }
import from walker_errors { WalkerError }
import from shared_graph { APP_DIR, run_walker }

"""Run a walker on the shared root (see shared_graph.run_walker). Under
`jac run` every `report` is also echoed to stdout; keep that out of the
script's own output."""
def walk(w: any) -> any {
    with redirect_stdout(io.StringIO()) {
        return run_walker(w);
    }
}

"""Check a deck list against a play format without making a deck, so a
rejected try leaves nothing behind. Reports the violations (an unresolved
card is left out, as it would be from the deck), or a WalkerError when the
list can't be read or the format is unknown."""
walker CheckList {
    has format: str,
        text: str,
        play_format: str,
        reports: list[list[Violation] | WalkerError] = [];

    can check with Root entry {
        rl = resolve_list(self.format, self.text);
        if isinstance(rl, WalkerError) {
            report rl;
            disengage;
        }
        fmt = format_node(here, self.play_format);
        if fmt is None {
            report WalkerError(code="unknown-format", message=f"Unknown format {self.play_format}.");
            disengage;
        }
        lines: list[CardLine] = [];
        for e in rl.entries {
            card = card_node(here, e.oracle_id);
            if card is not None {
                lines.append(card_line(card, e.zone, e.count));
            }
        }
        report check_lines(lines, fmt);
    }
}

"""True when the precon's list breaks none of `play_format`'s rules."""
def is_legal(source: DeckSource, precon: dict[str, str], play_format: str) -> bool {
    done = walk(CheckList(format="mtgjson", text=source.deck_text(precon["fileName"]), play_format=play_format));
    found = done.reports[0];
    return not isinstance(found, WalkerError) and len(found as list[Violation]) == 0;
}

"""Names of every deck already in the shared graph."""
def deck_names -> set[str] {
    decks = walk(ListDecks()).reports[0] as list[Deck];
    return {d.name for d in decks};
}

"""A deck's card counts for the output line, e.g. "1 commander + 99 main"."""
def card_count(view: DeckView) -> str {
    commander = sum([c.count for c in view.cards if c.zone == "commander"]);
    counts = f"{view.main_total} main";
    if view.sideboard_total {
        counts += f" + {view.sideboard_total} sideboard";
    }
    if commander {
        counts = f"{commander} commander + " + counts;
    }
    return counts;
}

"""Pick, check and create one precon for `play_format`; return its output line."""
def seed_format(source: DeckSource, deck_list: list[dict[str, str]], play_format: str, seed: int) -> str {
    deck_type = DECK_TYPES[play_format];
    left = candidates(deck_list, play_format, deck_names(), date.today());
    chosen: Pick | None = pick(
        left, format_rng(seed, play_format), lambda(p: dict[str, str]) -> bool { return is_legal(source, p, play_format); }, TRIES
    );
    if chosen is None {
        return f"{play_format}: no precon left to add (every released {deck_type} is already in the graph)";
    }
    precon = chosen.entry as dict[str, str];
    made = walk(
        CreateDeckFromList(format="mtgjson", text=source.deck_text(precon["fileName"]), play_format=play_format)
    ).reports[0];
    about = f"{precon['name']} ({deck_type}, released {precon.get('releaseDate') or 'unknown'})";
    if isinstance(made, WalkerError) {
        return f"{play_format}: {about} - not created: {made.message}";
    }
    result = made as NewDeckResult;
    if not result.deck_id {
        return f"{play_format}: {about} - not created: no card in it is in the catalogue";
    }
    view = walk(GetDeck(deck_id=result.deck_id)).reports[0] as DeckView;
    legal = "legal" if view.legal else f"illegal in {view.format}";
    if view.format != play_format {
        legal += f" (no {play_format} format yet, so it is checked as {view.format})";
    } elif chosen.legal {
        legal += f" (on try {len(chosen.tried)})";
    } else {
        legal += f" (no legal precon in {len(chosen.tried)} {'try' if len(chosen.tried) == 1 else 'tries'})";
    }
    # The MTGJSON parser also lists the deck file's non-card lists (tokens,
    # displayCommander, ...) it skipped; those are not unresolved cards.
    skipped = [u for u in result.unresolved if is_skipped_list_note(u)];
    unresolved = ", ".join([u for u in result.unresolved if u not in skipped]) or "none";
    line = f"{play_format}: {about} - {legal} - {card_count(view)} - unresolved: {unresolved}";
    if skipped {
        line += f" - skipped: {', '.join(skipped)}";
    }
    return line;
}

with entry:__main__ {
    parser = argparse.ArgumentParser(prog="jac run --no-serve seed.jac", description="Add one random MTGJSON precon per format to this checkout's graph.");
    parser.add_argument("--from-dir", `default="", help="read DeckList.json and deck files from this directory instead of mtgjson.com");
    parser.add_argument("--seed", `default="", help="random seed, to repeat a set of picks on a fresh graph");
    parser.add_argument("--format", action="append", choices=list(DECK_TYPES), help="only this format (repeatable)");
    args = parser.parse_args(sys.argv[1:]);
    # Resolve --from-dir before moving to the app's directory, where the graph lives.
    from_dir = os.path.abspath(args.from_dir) if args.from_dir else "";
    os.chdir(APP_DIR);

    check_catalogue();

    seed = int(args.seed) if args.seed else random.SystemRandom().randrange(1000000);
    only: list[str] = (args.format or []) as list[str];
    print(f"Seed: {seed} (use --seed {seed} to make the same picks on a fresh graph)");
    source = DeckSource(from_dir=from_dir or None);
    try {
        deck_list = source.deck_list();
        for play_format in [f for f in DECK_TYPES if not only or f in only] {
            print(seed_format(source, deck_list, play_format, seed));
        }
    } except URLError as err {
        sys.stderr.write(f"Could not download from mtgjson.com: {err.reason}. Use --from-dir for offline use.\n");  # jac:ignore[E1099]
        sys.exit(1);
    }
}
