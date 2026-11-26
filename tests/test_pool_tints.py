"""The chat views' pool gradient carries its own copy of the mana tints (they
cannot read the web app's global.css), so the copy must not drift from it."""

import json
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def test_chat_view_pool_tints_match_global_css():
    css = (ROOT / "global.css").read_text(encoding="utf-8")
    html = (ROOT / "ui" / "pool.html").read_text(encoding="utf-8")
    tokens = {m[0].upper(): m[1] for m in re.findall(r"--mana-([wubrgc]):\s*(#[0-9a-fA-F]{6})", css)}
    block = re.search(r"const POOL_TINTS = \{(.*?)\};", html, re.S).group(1)
    tints = {k: v for k, v in re.findall(r'(\w):\s*"(#[0-9a-fA-F]{6})"', block)}
    assert tints == tokens


def test_chat_view_pool_paper_matches_global_css():
    css = (ROOT / "global.css").read_text(encoding="utf-8")
    html = (ROOT / "ui" / "pool.html").read_text(encoding="utf-8")
    paper = re.search(r"--pool-paper:\s*(#[0-9a-fA-F]{6})", css).group(1)
    assert f'const POOL_PAPER = "{paper}"' in html


def test_set_pool_leaves_the_default_when_a_result_names_no_colours():
    script = re.search(r"<script>(.*?)</script>", (ROOT / "ui" / "pool.html").read_text(encoding="utf-8"), re.S).group(1)
    probe = script + (
        "\nconst set = [];"
        "\nglobalThis.document = { documentElement: { style: { setProperty: (k) => set.push(k) } } };"
        "\nsetPool(undefined);"
        "\nconsole.log(JSON.stringify(set));"
    )
    out = subprocess.run(["node", "-e", probe], capture_output=True, text=True, check=True).stdout
    assert out.strip() == "[]"


def _pool_js(expression: str) -> str:
    script = re.search(r"<script>(.*?)</script>", (ROOT / "ui" / "pool.html").read_text(encoding="utf-8"), re.S).group(1)
    probe = script + f"\nconsole.log(JSON.stringify({expression}));"
    return subprocess.run(["node", "-e", probe], capture_output=True, text=True, check=True).stdout.strip()


def _tint(letter: str) -> str:
    css = (ROOT / "global.css").read_text(encoding="utf-8")
    return re.search(rf"--mana-{letter.lower()}:\s*(#[0-9a-fA-F]{{6}})", css).group(1)


def test_two_or_more_colours_run_their_tints_in_wubrg_order():
    assert _pool_js('poolStops(["G", "U", "R"])') == json.dumps([_tint("U"), _tint("R"), _tint("G")], separators=(",", ":"))


def test_one_colour_runs_into_paper():
    assert _pool_js('poolStops(["G"])') == json.dumps([_tint("G"), "#ffffff"], separators=(",", ":"))


def test_colourless_runs_the_colourless_tint_into_paper():
    assert _pool_js("poolStops([])") == json.dumps([_tint("C"), "#ffffff"], separators=(",", ":"))


def test_off_a_deck_the_chat_default_runs_through_all_five_tints():
    html = (ROOT / "ui" / "pool.html").read_text(encoding="utf-8")
    five = ", ".join(_tint(c) for c in "WUBRG")
    assert f"--pool: linear-gradient(110deg, {five});" in html
    assert f"--pool-down: linear-gradient(180deg, {five});" in html


def test_off_a_deck_the_web_default_runs_through_all_five_mana_vars():
    css = (ROOT / "global.css").read_text(encoding="utf-8")
    five = ", ".join(f"var(--mana-{c})" for c in "wubrg")
    assert f"--pool: linear-gradient(110deg, {five});" in css
