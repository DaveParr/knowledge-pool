"""A mana cost as a row of symbol pills: "{1}{R} // {U}" -> (1)(R) // (U).

Each {...} symbol is one pill coloured by its mana colour; hybrid symbols
like {W/U} or {2/W} are split diagonally. The raw cost stays available to
screen readers through aria-label. The MCP views draw the same pills
(manaPills in ui/deck_table.html).
"""

import "./mana_cost.css";

glob MANA_COLOURS: list[str] = ["W", "U", "B", "R", "G"];

"""CSS colour variable for one part of a symbol ("R" -> red, "2" -> generic)."""
def partColour(part: str) -> str {
    return "var(--mana-" + part.lower() + ")" if part in MANA_COLOURS else "var(--mana-c)";
}

"""Background for a symbol: one colour, or a diagonal split for hybrids."""
def symbolBackground(sym: str) -> str {
    parts = [p for p in sym.split("/") if p != "P"];
    if len(parts) < 2 {
        return partColour(parts[0] if parts else sym);
    }
    return "linear-gradient(135deg, " + partColour(parts[0]) + " 50%, " + partColour(parts[1]) + " 50%)";
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
                    <span
                        key={str(i) + "-" + str(j)}
                        className="mc-sym"
                        style={{"background": symbolBackground(sym)}}
                    >
                        {sym}
                    </span>
                }
            }}
        </span>;
}
