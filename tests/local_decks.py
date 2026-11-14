"""The local user's decks in the database `JAC_DB_URL` names, read through the
runner in a fresh Jac process, as the MCP server and the seed script see them.

The web app cannot be asked: until the front door runs its calls (#129) it
acts as the guest, not the local user.
"""

import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Runs standalone, outside the project, so nothing is built. Prints each deck's
# view as one JSON object per line.
PROBE = """
import json, sys
from jaclang import JacRuntime as Jac
Jac.jac_import(target="runner", base_path=sys.argv[1], lng="jac")
Jac.jac_import(target="decks", base_path=sys.argv[1], lng="jac")
runner, decks = sys.modules["runner"], sys.modules["decks"]
runner.start()
for d in runner.run_as(runner.LOCAL_USER, decks.ListDecks()).reports[0]:
    view = runner.run_as(runner.LOCAL_USER, decks.GetDeck(deck_id=Jac.object_ref(d))).reports[0]
    zones = {}
    for c in view.cards:
        zones[c.zone] = zones.get(c.zone, 0) + c.count
    print(json.dumps({"name": view.name, "format": view.format, "zones": zones, "legal": view.legal}))
"""


def local_user_decks(db_url: str, tmp_path: Path) -> dict[str, dict]:
    """Every deck the local user has, by name: its play format, card counts per
    zone and whether it is legal."""
    probe = tmp_path / "local_decks_probe.py"
    probe.write_text(PROBE)
    env = {**os.environ, "JAC_DB_URL": db_url}
    run = subprocess.run(
        [sys.executable, "run", "--no-serve", "--no-takeover", str(probe), str(ROOT)],
        cwd=ROOT, env=env, capture_output=True, text=True, timeout=300,
    )
    assert run.returncode == 0, run.stdout + run.stderr
    found = [json.loads(line) for line in run.stdout.splitlines() if line.startswith("{")]
    return {d.pop("name"): d for d in found}
