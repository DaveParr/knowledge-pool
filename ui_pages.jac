"""The MCP Apps views' pages: each file in `ui/`, with the parts the views
share (`ui/refusal.html`) put in where it has an `@include` comment."""

import os;

glob UI_DIR: str = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ui"),
     INCLUDE_REFUSAL: str = "<!-- @include refusal.html -->";

"""The page of the view in `ui/<name>`, ready to hand to a host."""
def view_page(name: str) -> str {
    with open(os.path.join(UI_DIR, name), encoding="utf-8") as f {
        page = f.read();
    }
    with open(os.path.join(UI_DIR, "refusal.html"), encoding="utf-8") as f {
        shared = f.read();
    }
    return page.replace(INCLUDE_REFUSAL, shared);
}
