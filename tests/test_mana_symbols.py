"""Mana costs and rules-text symbols drawn with the Mana font (#238).

Seams: the chat views' shared script (ui/mana_symbols.html, run under node), the stylesheet
both views and the web app use (mana_symbols.css), the web app's own list of special symbols
(mana_cost.jac), and the font licence kept in the repo.
"""

import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
CSS = (ROOT / "mana_symbols.css").read_text()
VIEW_SCRIPT = (ROOT / "ui" / "mana_symbols.html").read_text()

# Every kind of symbol the ticket names, as written in a cost or in rules text.
COLOURS = ["W", "U", "B", "R", "G"]
HYBRID = ["W/U", "W/B", "U/B", "U/R", "B/R", "B/G", "R/W", "R/G", "G/W", "G/U"]
TWOBRID = [f"2/{c}" for c in COLOURS]
COLOURLESS_HYBRID = [f"C/{c}" for c in COLOURS]
PHYREXIAN = [f"{c}/P" for c in COLOURS]
HYBRID_PHYREXIAN = [f"{h}/P" for h in HYBRID]
SYMBOLS = {
    "colours": COLOURS,
    "generic": [str(n) for n in range(21)] + ["100", "1000000"],
    "variables, colourless and snow": ["X", "Y", "Z", "C", "S"],
    "hybrid": HYBRID,
    "two-brid": TWOBRID,
    "colourless hybrid": COLOURLESS_HYBRID,
    "Phyrexian": PHYREXIAN,
    "hybrid Phyrexian": HYBRID_PHYREXIAN,
    "colourless Phyrexian": ["C/P"],
    "halves": ["HW", "HR", "½"],
    "infinity and energy": ["∞", "E"],
    "tap, untap and the rest": ["T", "Q", "CHAOS", "A", "TK"],
}
ALL_SYMBOLS = [s for group in SYMBOLS.values() for s in group]


def css_rules(css: str) -> list[tuple[list[str], str]]:
    """(selectors, body) for each top-level rule that has braces and is not an @-block."""
    found = []
    for match in re.finditer(r"([^{}@]+)\{([^{}]*)\}", re.sub(r"/\*.*?\*/", "", css, flags=re.S)):
        found.append(([s.strip() for s in match.group(1).split(",")], match.group(2)))
    return found


def drawn_by_font(cls: str) -> bool:
    """True if the stylesheet gives `.<cls>` a glyph: a ::before rule with `content`."""
    return any(
        f".{cls}::before" in selectors and "content" in body
        for selectors, body in css_rules(CSS)
    )


def run_view_script(expression: str):
    """Evaluate `expression` (JSON-able) with the chat views' shared script loaded under node."""
    if shutil.which("node") is None:
        pytest.skip("no node")
    script = re.search(r"<script>(.*)</script>", VIEW_SCRIPT, re.S).group(1)
    done = subprocess.run(
        ["node", "-e", script + f"\nconsole.log(JSON.stringify({expression}))"],
        capture_output=True, text=True, timeout=30,
    )
    assert done.returncode == 0, done.stderr
    return json.loads(done.stdout)


def view_classes(symbol: str) -> list[str]:
    """The Mana classes the chat views draw for one symbol, from `manaPills`."""
    html = run_view_script(f"manaPills({json.dumps('{' + symbol + '}')})")
    return re.findall(r'<i class="ms ms-cost (ms-[a-z0-9-]+)"', html)


@pytest.mark.parametrize("symbol", ALL_SYMBOLS)
def test_a_symbol_the_catalogue_uses_is_drawn_as_one_glyph_the_font_has(symbol):
    classes = view_classes(symbol)
    assert len(classes) == 1, f"{symbol}: {classes}"
    assert drawn_by_font(classes[0]), f"{symbol} -> .{classes[0]} has no glyph in mana_symbols.css"


def test_colourless_phyrexian_draws_the_phyrexian_glyph_on_the_colourless_ground():
    assert view_classes("C/P") == ["ms-p"]
    ground = [b for selectors, b in css_rules(CSS) if selectors == [".ms-cost"]]
    assert len(ground) == 1 and "background-color: #beb9b2" in ground[0]
    assert not any(".ms-cost.ms-p" in selectors and "background" in b for selectors, b in css_rules(CSS))


def test_a_half_symbol_shows_the_left_half_of_the_whole_one():
    html = run_view_script("manaPills('{HW}')")
    assert '<span class="ms-half"><i class="ms ms-cost ms-w"' in html


def test_a_cost_is_a_row_of_symbols_that_screen_readers_get_whole():
    html = run_view_script("manaPills('{1}{R} // {U}')")
    assert html.count('class="mc-sym"') == 3
    assert 'aria-label="Mana cost {1}{R} // {U}"' in html
    assert html.count('class="mc-sep"') == 1


def test_a_card_without_a_cost_draws_no_symbols():
    assert run_view_script("manaPills('')") == ""


def test_rules_text_draws_its_symbols_inline_and_keeps_the_words():
    html = run_view_script("rulesHtml('{T}: Add {G}.')")
    assert html.startswith('<span class="mc-inline"><i class="ms ms-cost ms-tap"')
    assert 'ms-cost ms-g"' in html and html.endswith(": Add " + html.split(": Add ")[1])
    assert "}" not in re.sub(r"<[^>]*>", "", html)


def test_rules_text_is_escaped_before_its_symbols_are_drawn():
    html = run_view_script("rulesHtml('<b>{R}</b> & {nonsense\"}')")
    assert "<b>" not in html and "&lt;b&gt;" in html and "&amp;" in html
    assert html.count("<i ") == 2 and 'ms-nonsense"' not in html  # a bad symbol can't break out of the class


def test_the_web_app_and_the_chat_views_share_the_same_special_symbols():
    jac = (ROOT / "mana_cost.jac").read_text()
    block = re.search(r"SPECIAL_CLASSES: dict\[str, str\] = \{(.*?)\};", jac, re.S).group(1)
    web = dict(re.findall(r'"([^"]+)":\s*"([^"]+)"', block))
    views = re.search(r"const MANA_SPECIAL = \{(.*?)\};", VIEW_SCRIPT, re.S).group(1)
    chat = {k.strip('"'): v for k, v in re.findall(r'("?[^\s:,"]+"?|"[^"]+"):\s*"([^"]+)"', views)}
    assert web == chat


def test_the_mana_tokens_take_the_fonts_symbol_fills():
    tokens = dict(re.findall(r"--mana-([wubrgc]):\s*(#[0-9a-f]{6})", (ROOT / "global.css").read_text()))
    assert tokens == {
        "w": "#f0f2c0", "u": "#b5cde3", "b": "#aca29a", "r": "#db8664", "g": "#93b483", "c": "#beb9b2",
    }
    fills = {"c": re.search(r"background-color:\s*(#[0-9a-f]{6})", dict((tuple(s), b) for s, b in css_rules(CSS))[(".ms-cost",)]).group(1)}
    for selectors, body in css_rules(CSS):
        fill = re.search(r"background-color:\s*(#[0-9a-f]{6})", body)
        for selector in selectors:
            single = re.fullmatch(r"\.ms-cost\.ms-([wubrgc])", selector)
            if single and fill:
                fills[single.group(1)] = fill.group(1)
    assert fills == tokens


def test_the_font_is_inlined_and_cut_down_to_the_symbols_used():
    urls = re.findall(r"url\(([^)]*)\)", CSS)
    assert len(urls) == 1 and urls[0].strip("\"'").startswith("data:font/woff2;base64,")
    assert (ROOT / "mana_symbols.css").stat().st_size < 60_000  # the whole bundle's CSS and fonts weigh 187 KB


def test_the_font_licence_is_in_the_repo_and_named_in_the_stylesheet():
    licence = ROOT / "licenses" / "mana-font-OFL.txt"
    assert licence.exists(), "the OFL requires its text to travel with the font"
    text = licence.read_text()
    assert "SIL OPEN FONT LICENSE Version 1.1" in text
    assert "Andrew Gioia" in text
    assert "licenses/mana-font-OFL.txt" in CSS.split("*/")[0]
