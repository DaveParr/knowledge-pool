"""The MCP Apps views' pages: each file in `ui/`, with the parts the views
share (`SHARED`) put in where it has an `@include` comment."""

import os;

glob UI_DIR: str = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ui"),
     SHARED: list[str] = ["refusal.html", "host_container.html"];

"""The page of the view in `ui/<name>`, ready to hand to a host."""
def view_page(name: str) -> str {
    with open(os.path.join(UI_DIR, name), encoding="utf-8") as f {
        page = f.read();
    }
    for part in SHARED {
        with open(os.path.join(UI_DIR, part), encoding="utf-8") as f {
            page = page.replace(f"<!-- @include {part} -->", f.read());
        }
    }
    return page;
}
