"""The zones of a deck, in display order, and their titles: the one definition every view reads.
Deck code imports them from `decks`, which re-exports them."""

"""Every zone a deck can hold cards in (the mtgdeck/1 zones), in display
order. The one list of zones: every holdings change and every import checks
against it. Constructed legality looks only at main and sideboard (see
legality.LEGALITY_ZONES); Commander also counts the commander and companion zones."""
glob ZONES: list[str] = ["commander", "companion", "main", "sideboard", "maybeboard"],
     # Each zone's heading in every view of a deck.
     ZONE_TITLES: dict[str, str] = {
         "commander": "Commander",
         "companion": "Companion",
         "main": "Main deck",
         "sideboard": "Sideboard",
         "maybeboard": "Maybeboard"
     };

"""The zones whose cards a deck needs to be played: every zone but the maybeboard.
Missing cards and sleeveable count these, from this one list."""
glob PLAYED_ZONES: list[str] = [z for z in ZONES if z != "maybeboard"];

"""The zones in display order as {key, title} pairs, for views that are sent data, not code."""
def zone_choices -> list[dict[str, str]] {
    return [{"key": z, "title": ZONE_TITLES[z]} for z in ZONES];
}

"""The zone keys as they read in a tool description: "commander" | "companion" | ..."""
def zone_options -> str {
    return " | ".join([f'"{z}"' for z in ZONES]);
}
