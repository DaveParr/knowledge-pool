"""S02 spike: the full card catalogue as a Jac graph, and a FindSynergies walker.

Builds Card, Theme and Role nodes plus Enables, PaysOff and HasRole edges from
rule-based tags, held in memory (not attached to `root`, so nothing is saved).
FindSynergies starts from a deck and returns ranked candidates with a score
breakdown.
"""

import re;
import sqlite3;
import json;

node Card {
    has oracle_id: str,
        name: str,
        mana_value: float,
        types: list[str],
        text: str,
        legal: dict[str, str];
}

node Theme {
    has name: str;
}

node Role {
    has name: str;
}

node Catalog {}

node Deck {
    has name: str,
        format: str;
}

edge Lists: Catalog --> Card {}
edge Enables: Card --> Theme {}
edge PaysOff: Card --> Theme {}
edge HasRole: Card --> Role {}
edge Holds: Deck --> Card {
    has count: int = 1;
}

"""A rule-based theme: rules text that makes a card an enabler, or a payoff."""
obj ThemeRule {
    has name: str,
        enables: str,
        pays_off: str,
        enabler_types: list[str] = [];
}

glob THEME_RULES: list[ThemeRule] = [
    ThemeRule(
        name="tokens",
        enables=r"\bcreates? (?:a|an|one|two|three|four|five|x|that many|[0-9]+) .*?tokens?\b",
        pays_off=r"whenever (?:a|another|one or more) (?:nontoken )?(?:creature|token)s? (?:you control )?enters?|for each (?:creature|token) you control|creatures you control get \+"
    ),
    ThemeRule(
        name="sacrifice",
        enables=r"sacrifice (?:a|another|an) (?:creature|artifact|permanent|token)",
        pays_off=r"whenever (?:a|another|one or more) (?:nontoken )?creatures? (?:you control )?dies?|whenever you sacrifice"
    ),
    ThemeRule(
        name="landfall",
        enables=r"(?:put|search your library for) (?:a|up to \w+|two|x) (?:basic )?lands? cards?.*?onto the battlefield|you may play an additional land|play lands from your graveyard",
        pays_off=r"\blandfall\b|whenever a land (?:you control )?enters"
    ),
    ThemeRule(
        name="counters",
        enables=r"put (?:a|an|one|two|three|x|that many|[0-9]+) \+1/\+1 counters? on",
        pays_off=r"\+1/\+1 counters? (?:is|are) put on|for each \+1/\+1 counter|\bproliferate\b|with a \+1/\+1 counter on it"
    ),
    ThemeRule(
        name="graveyard",
        enables=r"\bmill\b|\bsurveil\b|put (?:the top|that card|it) .*?into your graveyard",
        pays_off=r"\bflashback\b|\bescape\b|\bdelve\b|\bunearth\b|cast .*? from your graveyard|return .*? from your graveyard to the battlefield"
    ),
    ThemeRule(
        name="spells",
        enables="",
        pays_off=r"whenever you cast (?:an|a) (?:instant|sorcery|noncreature)|\bprowess\b|\bmagecraft\b",
        enabler_types=["Instant", "Sorcery"]
    )
];

glob ROLE_RULES: dict[str, str] = {
    "removal": r"destroy target|exile target (?:creature|permanent|nonland)|deals? (?:[0-9]+|x) damage to (?:any target|target creature)",
    "ramp": r"add \{|search your library for (?:a|up to \w+) (?:basic )?lands?",
    "card draw": r"\bdraws? (?:a|two|three|x) cards?",
    "counterspell": r"counter target (?:spell|creature|noncreature|instant)",
    "sweeper": r"destroy all|exile all|deals? (?:[0-9]+|x) damage to each creature"
};

"""Everything the loader built, so callers can reach nodes without a graph walk."""
obj LoadedCatalog {
    has hub: Catalog,
        by_name: dict[str, Card],
        themes: dict[str, Theme],
        roles: dict[str, Role],
        counts: dict[str, int];
}

"""Read the SQLite catalogue and build the whole graph in memory."""
def load_catalog(db_path: str) -> LoadedCatalog {
    con = sqlite3.connect(db_path);
    hub = Catalog();
    themes: dict[str, Theme] = {};
    for rule in THEME_RULES {
        themes[rule.name] = Theme(name=rule.name);
    }
    roles: dict[str, Role] = {};
    for name in ROLE_RULES.keys() {
        roles[name] = Role(name=name);
    }
    enables_re = {r.name: re.compile(r.enables) if r.enables else None for r in THEME_RULES};
    pays_re = {r.name: re.compile(r.pays_off) for r in THEME_RULES};
    role_re = {k: re.compile(v) for (k, v) in ROLE_RULES.items()};
    by_name: dict[str, Card] = {};
    counts = {"cards": 0, "enables": 0, "pays_off": 0, "has_role": 0};
    for row in con.execute(
        "SELECT oracle_id, name, mana_value, types, text, legalities FROM cards"
    ) {
        types = json.loads(row[3] as str) as list[str];
        text = (row[4] as str).lower();
        card = Card(
            oracle_id=row[0] as str,
            name=row[1] as str,
            mana_value=row[2] as float,
            types=types,
            text=text,
            legal=json.loads(row[5] as str) as dict[str, str]
        );
        hub +>:Lists:+> card;
        by_name[card.name] = card;
        counts["cards"] += 1;
        for rule in THEME_RULES {
            rx = enables_re[rule.name];
            if (rx is not None and rx.search(text)) or any([t in types for t in rule.enabler_types]) {
                card +>:Enables:+> themes[rule.name];
                counts["enables"] += 1;
            }
            if pays_re[rule.name].search(text) {
                card +>:PaysOff:+> themes[rule.name];
                counts["pays_off"] += 1;
            }
        }
        for (rname, rx) in role_re.items() {
            if rx.search(text) {
                card +>:HasRole:+> roles[rname];
                counts["has_role"] += 1;
            }
        }
    }
    con.close();
    return LoadedCatalog(hub=hub, by_name=by_name, themes=themes, roles=roles, counts=counts);
}

"""One suggested card and why."""
obj Suggestion {
    has name: str,
        score: float,
        breakdown: dict[str, float];
}

"""Start at a deck; step to its cards, then their themes, then the other cards on
those themes. Each candidate scores for paying off themes the deck enables, and
for enabling themes the deck pays off. Legal cards in the deck's format only."""
walker FindSynergies {
    has top: int = 20,
        deck_ids: set[str] = set(),
        enablers: dict[str, int] = {},
        payoffs: dict[str, int] = {},
        fmt: str = "",
        scores: dict[str, dict[str, float]] = {},
        cards: dict[str, Card] = {},
        visited_themes: set[str] = set(),
        result: list[Suggestion] = [];

    can start with Deck entry {
        self.fmt = here.format;
        deck_cards = [here ->:Holds:->];
        for c in deck_cards {
            self.deck_ids.add(c.oracle_id);
            n = [edge here ->:Holds:-> c][0].count;
            for t in [c ->:Enables:->] {
                self.enablers[t.name] = self.enablers.get(t.name, 0) + n;
            }
            for t in [c ->:PaysOff:->] {
                self.payoffs[t.name] = self.payoffs.get(t.name, 0) + n;
            }
        }
        visit deck_cards;
    }

    can from_card with Card entry {
        visit [here ->:Enables:->] + [here ->:PaysOff:->];
    }

    can from_theme with Theme entry {
        if here.name in self.visited_themes {
            skip;
        }
        self.visited_themes.add(here.name);
        deck_enables = self.enablers.get(here.name, 0);
        deck_pays = self.payoffs.get(here.name, 0);
        if deck_enables > 0 {
            for c in [here <-:PaysOff:<-] {
                self.add(c, f"pays off {here.name}", float(deck_enables));
            }
        }
        if deck_pays > 0 {
            for c in [here <-:Enables:<-] {
                self.add(c, f"enables {here.name}", 0.5 * float(deck_pays));
            }
        }
    }

    def add(c: Card, why: str, points: float) {
        if c.oracle_id in self.deck_ids or c.legal.get(self.fmt) != "Legal" {
            return;
        }
        parts = self.scores.get(c.oracle_id);
        if parts is None {
            parts = {};
            self.scores[c.oracle_id] = parts;
            self.cards[c.oracle_id] = c;
        }
        parts[why] = parts.get(why, 0.0) + points;
    }

    can finish with Deck exit {
        totals: list[tuple[float, str]] = [];
        for (oid, parts) in self.scores.items() {
            totals.append((sum(list(parts.values())), oid));
        }
        totals.sort(reverse=True);
        self.result = [
            Suggestion(name=self.cards[oid].name, score=total, breakdown=self.scores[oid])
            for (total, oid) in totals[:self.top]
        ];
    }
}

"""A 60-card deck node over catalogue cards, from {name: count}."""
def make_deck(cat: LoadedCatalog, name: str, fmt: str, lines: dict[str, int]) -> Deck {
    deck = Deck(name=name, format=fmt);
    for (card_name, n) in lines.items() {
        deck +>:Holds(count=n):+> cat.by_name[card_name];
    }
    return deck;
}
