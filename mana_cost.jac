"""Magic's own symbols for mana costs and rules text: "{1}{R} // {U}" -> (1)(R) // (U).

Each {...} symbol is drawn with the Mana font (mana_symbols.css, built by
scripts/mana_symbols.py): coloured, hybrid, Phyrexian, generic numbers, X, snow, tap,
untap and the rest. The raw text stays available to screen readers through aria-label.
The MCP views draw the same symbols (manaPills in ui/deck_table.html).
"""

import "./mana_symbols.css";
import "./mana_cost.css";

"""Symbols whose Mana class isn't their letters: tap, untap, half, infinity and the like.
Colourless Phyrexian {C/P} has no glyph of its own: the Phyrexian glyph on the colourless
ground is how it is printed."""
glob SPECIAL_CLASSES: dict[str, str] = {
    "T": "tap",
    "Q": "untap",
    "½": "1-2",
    "∞": "infinity",
    "CHAOS": "chaos",
    "A": "acorn",
    "TK": "ticket",
    "C/P": "p",
    "HW": "w",
    "HR": "r",
};

"""The Mana font class for one symbol: "W/U" -> "ms-wu", "T" -> "ms-tap", "12" -> "ms-12"."""
def manaClass(sym: str) -> str {
    if sym in SPECIAL_CLASSES {
        return "ms-" + SPECIAL_CLASSES[sym];
    }
    letters = "";
    for part in sym.lower().split("/") {
        letters = letters + part;
    }
    return "ms-" + letters;
}

"""One symbol. Half symbols ({HW}, {HR}) show the left half of the whole one."""
def:pub ManaSymbol(sym: str) -> JsxElement {
    glyph = <i className={"ms ms-cost " + manaClass(sym)} role="img" aria-label={"{" + sym + "}"}/>;
    if len(sym) == 2 and sym.startswith("H") {
        return <span className="ms-half">{glyph}</span>;
    }
    return glyph;
}

"""Symbols in one face's cost: "{1}{R}" -> ["1", "R"]."""
def symbols(face: str) -> list[str] {
    return [s.strip().lstrip("{") for s in face.split("}") if s.strip().lstrip("{")];
}

def:pub ManaCost(cost: str) -> JsxElement {
    if not cost {
        return <span className="mc-cost"/>;
    }
    faces = cost.split("//");
    return
        <span className="mc-cost" role="img" aria-label={"Mana cost " + cost}>
            {for (i, face) in enumerate(faces) {
                if i > 0 {
                    <span key={"sep" + str(i)} className="mc-sep">//</span>
                }
                for (j, sym) in enumerate(symbols(face)) {
                    <span key={str(i) + "-" + str(j)} className="mc-sym" aria-hidden="true">
                        <ManaSymbol sym={sym}/>
                    </span>
                }
            }}
        </span>;
}

"""Rules text with its {...} symbols drawn inline: "{T}: Add {G}." -> (tap): Add (G)."""
def:pub RulesText(text: str) -> JsxElement {
    chunks = text.split("{");
    return
        <span className="mc-text">
            {chunks[0]}
            {for (i, chunk) in enumerate(chunks[1:]) {
                parts = chunk.split("}");
                if len(parts) > 1 {
                    <span key={str(i)}>
                        <span className="mc-inline"><ManaSymbol sym={parts[0]}/></span>
                        {parts[1]}
                    </span>
                } else {
                    <span key={str(i)}>{"{" + chunk}</span>
                }
            }}
        </span>;
}
