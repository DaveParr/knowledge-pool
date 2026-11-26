"""The chat views' pool gradient carries its own copy of the mana tints (they
cannot read the web app's global.css), so the copy must not drift from it."""

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
