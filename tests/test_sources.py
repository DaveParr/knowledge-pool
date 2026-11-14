"""Rules about the app's own source code."""

import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def test_app_code_never_reads_a_nodes_raw_anchor():
    """A shared card's raw anchor (`__jac__`, and its `edges`) holds every
    user's edges to it, whoever reads it. No app code may read it."""
    sources = [*ROOT.glob("*.jac"), *ROOT.glob("catalog/*.py"), *ROOT.glob("deckformats/*.py")]
    assert any(p.name == "decks.jac" for p in sources)
    offenders = [p.name for p in sources if p.is_file() and re.search(r"__jac__", p.read_text())]
    assert offenders == []
