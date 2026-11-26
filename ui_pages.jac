"""The MCP Apps views' pages: each file in `ui/`, with the parts the views
share (`SHARED`) put in where it has an `@include` comment. `ui/pool.html` is
the pool gradient in the deck's colours; `ui/mana_symbols.html`
carries the repo's `mana_symbols.css` (Magic's symbols from the Mana font, the
same stylesheet the web app imports) at its `MANA_CSS_MARKER`."""

import os;

glob ROOT_DIR: str = os.path.dirname(os.path.abspath(__file__)),
     UI_DIR: str = os.path.join(ROOT_DIR, "ui"),
     SHARED: list[str] = ["refusal.html", "host_container.html", "pool.html", "mana_symbols.html"],
     MANA_CSS_MARKER: str = "/* @mana_symbols.css */";

def read_text(path: str) -> str {
    with open(path, encoding="utf-8") as f {
        return f.read();
    }
}

"""The page of the view in `ui/<name>`, ready to hand to a host."""
def view_page(name: str) -> str {
    page = read_text(os.path.join(UI_DIR, name));
    mana_css = read_text(os.path.join(ROOT_DIR, "mana_symbols.css"));
    for part in SHARED {
        shared = read_text(os.path.join(UI_DIR, part)).replace(MANA_CSS_MARKER, mana_css);
        page = page.replace(f"<!-- @include {part} -->", shared);
    }
    return page;
}
