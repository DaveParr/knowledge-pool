"""UI smoke test: drive the real web app and the deck_table MCP Apps view in a headless
browser (`jac browse`), so a broken UI fails pytest and CI instead of waiting for a
hand check (#80).

Runs scripts/dev.sh against the small fixture catalogue and a throwaway database. With no
browser it skips, unless KP_REQUIRE_BROWSER=1 (set in CI), when it fails.
"""

import json
import os
import re
import socket
import subprocess
import sys
from pathlib import Path

import anyio
from contextlib import contextmanager
import pytest
from mcp.client.session import ClientSession
from mcp.client.streamable_http import streamable_http_client

from catalog.ingest import build, load_atomic, load_oracle_tags
from tests.databases import fresh_database

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "dev.sh"
FIXTURES = ROOT / "tests" / "fixtures"
ARTIFACTS = ROOT / "test-artifacts" / "ui_smoke"
WAIT_MS = 30000


def free_port_pair() -> int:
    """A port P where both P and P + 1 are free (the front door and its child, Jac's server).

    Scans 9100-9898, above the kernel's ephemeral range and clear of dev.sh's 8100-8898.
    """
    for port in range(9100, 9900, 2):
        try:
            for p in (port, port + 1):
                with socket.socket() as s:
                    s.bind(("127.0.0.1", p))
        except OSError:
            continue
        return port
    raise RuntimeError("no free port pair")


class App:
    def __init__(self, web: str, mcp: str, session: str, env: dict):
        self.web, self.mcp, self.session, self.env = web, mcp, session, env
        self.transcript: list[str] = []

    def browse(self, *args: str) -> str:
        run = subprocess.run(
            [sys.executable, "browse", "-s", self.session, *args],
            cwd=ROOT, capture_output=True, text=True, timeout=120,
        )
        out = (run.stdout + run.stderr).strip()
        self.transcript.append(f"$ jac browse {' '.join(args)}\n{out}\n")
        assert run.returncode == 0 and "✖" not in out, f"jac browse {' '.join(args)} failed:\n{out}"
        return out

    def ref(self, role: str, name: str, nth: int = 0) -> str:
        """The @eN ref of the nth snapshot node with this role and exact name."""
        pattern = re.compile(rf'^\s*(@e\d+) {re.escape(role)} "{re.escape(name)}"', re.M)
        found = pattern.findall(self.browse("snapshot"))
        assert len(found) > nth, f'no {role} "{name}" on the page'
        return found[nth]

    def click(self, role: str, name: str, nth: int = 0) -> None:
        self.browse("click", self.ref(role, name, nth))

    def fill(self, selector: str, text: str) -> None:
        self.browse("wait", selector)
        self.browse("fill", selector, text)

    def js(self, expression: str) -> str:
        return self.browse("eval", expression)

    def wait_text(self, text: str, within: str = "body") -> str:
        """Wait (inside the page) until `within` shows `text`; return that element's text."""
        selector, needle = json.dumps(within), json.dumps(text)
        return self.js(
            f"""new Promise((resolve, reject) => {{
              const deadline = Date.now() + {WAIT_MS};
              const look = () => {{
                const el = document.querySelector({selector});
                const shown = el ? el.innerText : "";
                if (shown.includes({needle})) resolve(shown);
                else if (Date.now() > deadline) reject(new Error("never saw " + {needle} + " in " + {selector} + "; saw: " + shown));
                else requestAnimationFrame(look);
              }};
              look();
            }})"""
        )


def have_browser(session: str) -> str | None:
    """None if a headless browser launches, else why not."""
    run = subprocess.run(
        [sys.executable, "browse", "-s", session, "open", "about:blank"],
        cwd=ROOT, capture_output=True, text=True, timeout=120,
    )
    if run.returncode == 0 and "✖" not in run.stdout + run.stderr:
        return None
    return (run.stdout + run.stderr).strip()[-500:]


def save_artifacts(app: App, log: Path) -> None:
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    (ARTIFACTS / "browse.log").write_text("\n".join(app.transcript))
    if log.exists():
        (ARTIFACTS / "server.log").write_text(log.read_text())
    subprocess.run(
        [sys.executable, "browse", "-s", app.session, "screenshot", str(ARTIFACTS / "final.png")],
        cwd=ROOT, capture_output=True, timeout=60,
    )


@pytest.fixture(scope="module")
def app(tmp_path_factory, request, test_postgres):
    work = tmp_path_factory.mktemp("ui_smoke")
    port = free_port_pair()
    session = f"kp-smoke-{port}"
    problem = have_browser(session)
    if problem:
        subprocess.run([sys.executable, "browse", "-s", session, "close"], cwd=ROOT, capture_output=True, timeout=60)
        if os.environ.get("KP_REQUIRE_BROWSER") == "1":
            pytest.fail(f"KP_REQUIRE_BROWSER=1 but no browser launches: {problem}")
        pytest.skip(f"no headless browser for `jac browse`: {problem}")

    catalog = work / "catalog.sqlite"
    build(load_atomic(FIXTURES / "atomic_small.json"), catalog, tags=load_oracle_tags(FIXTURES / "oracle_tags_small.jsonl"))
    env = {
        **os.environ,
        "KP_DEV_DIR": str(work / "dev"),
        "KP_DEV_PORT": str(port),
        "KP_CATALOG": str(catalog),
    }
    log = work / "dev" / "server.log"
    with fresh_database(test_postgres) as db_url, _served({**env, "JAC_DB_URL": db_url}, session, log, port, request) as the_app:
        yield the_app


@contextmanager
def _served(env: dict, session: str, log: Path, port: int, request):
    try:
        up = subprocess.run([str(SCRIPT), "up"], env=env, cwd=ROOT, capture_output=True, text=True, timeout=300)
        assert up.returncode == 0, up.stdout + up.stderr
        the_app = App(f"http://127.0.0.1:{port}", f"http://127.0.0.1:{port}/mcp", session, env)
        yield the_app
        if request.session.testsfailed:
            save_artifacts(the_app, log)
    finally:
        subprocess.run([sys.executable, "browse", "-s", session, "close"], cwd=ROOT, capture_output=True, timeout=60)
        subprocess.run([str(SCRIPT), "down"], env=env, cwd=ROOT, timeout=60)


def test_build_a_deck_through_the_web_app(app):
    app.browse("open", app.web)
    app.fill("input[aria-label='Deck name']", "Smoke Burn")
    app.click("button", "Create deck")
    app.browse("wait", "a")
    app.click("link", "Smoke Burn")

    app.wait_text("Not legal")
    app.fill("input[placeholder='Card name, type or rules text']", "Lightning Bolt")
    app.click("button", "Search")
    app.wait_text("1 card matches")
    app.click("button", "Add Lightning Bolt to main deck")

    deck = app.wait_text("Lightning Bolt", within="ul.dd-cards")
    page = app.wait_text("Main deck")
    assert "Lightning Bolt" in deck
    assert "Not legal" in page
    assert "at least 60" in page  # 1 card is under the 60-card minimum

    # Expanding the card line shows its rules text in the deck (the search hit has it too).
    app.js("document.querySelector('ul.dd-cards summary').click()")
    assert "deals 3 damage" in app.wait_text("deals 3 damage", within="ul.dd-cards")


def test_the_page_says_other_users_can_see_and_copy_your_decks(app):
    app.browse("open", app.web)
    assert "Other users can see and copy the decks you make" in app.wait_text("Other users can see")


def test_the_connector_address_is_shown_and_copied_and_local_mode_has_no_sign_out(app):
    app.browse("open", app.web)
    app.browse("wait", "input[aria-label='Connector address']")
    address = app.js("document.querySelector(\"input[aria-label='Connector address']\").value")
    assert address.strip().strip("\"") == app.web + "/mcp", address
    app.click("button", "Copy")
    assert app.wait_text("Copied", within=".sb-connector")
    # Local mode has no browser session to end, so no "Sign out".
    assert "Sign out" not in app.js("document.body.innerText")


def test_the_page_watches_its_calls_for_an_ended_session(app):
    app.browse("open", app.web)
    app.browse("wait", "input[aria-label='Connector address']")
    assert "native code" not in app.js("window.fetch.toString()")


def test_a_decks_format_pill_ignores_what_is_typed_in_the_name_box(app):
    app.browse("open", app.web)
    app.fill("input[aria-label='Deck name']", "Pill Deck")
    app.click("button", "Create deck")
    app.wait_text("Pill Deck", within="ul.fe-decks")
    shown = app.wait_text("Standard", within="ul.fe-decks .pill")

    app.fill("input[aria-label='Deck name']", "qa deck")
    pills = app.js("JSON.stringify([...document.querySelectorAll('ul.fe-decks .pill')].map(p => p.innerText))")
    assert "qa deck" not in pills, pills
    assert shown == "Standard"


async def deck_show_result(url: str) -> dict:
    """deck_show's structuredContent for the "Smoke Burn" deck (created if missing)."""

    async def call(session, tool, **args):
        result = await session.call_tool(tool, args)
        assert not result.is_error, (tool, result.content)
        sc = result.structured_content
        if sc is None:
            return json.loads(result.content[0].text)
        return sc["result"] if set(sc) == {"result"} else sc

    async with streamable_http_client(url) as (read, write), ClientSession(read, write) as session:
        await session.initialize()
        decks = await call(session, "deck_list")
        deck = next((d for d in decks if d["name"] == "Smoke Burn"), None)
        if deck is None:
            deck = await call(session, "deck_create", name="Smoke Burn", format="standard")
        shown = await call(session, "deck_show", deck_id=deck["id"])
        if not any(c["name"] == "Lightning Bolt" and c["zone"] == "main" for c in shown["cards"]):
            resolved = await call(session, "resolve_names", names=["Lightning Bolt"])
            await call(session, "deck_edit", deck_id=deck["id"], changes=[
                {"oracle_id": resolved["exact"][0]["oracle_id"], "count": 1, "zone": "main", "reason": "smoke test"},
            ])
        return await call(session, "deck_show", deck_id=deck["id"])


def test_deck_table_view_renders_a_real_deck_show_result(app):
    shown = anyio.run(deck_show_result, app.mcp)
    bolt = next(c for c in shown["cards"] if c["name"] == "Lightning Bolt" and c["zone"] == "main")

    app.browse("open", (ROOT / "ui" / "deck_table.html").as_uri())
    app.browse("wait", "#app")
    message = {"jsonrpc": "2.0", "method": "ui/notifications/tool-result", "params": {"structuredContent": shown}}
    app.js(f'window.postMessage({json.dumps(message)}, "*")')

    table = app.wait_text("Lightning Bolt", within="#app")
    assert "Smoke Burn" in table
    row = app.js("document.querySelector('#app ul[data-zone=\"main\"] summary').innerText")
    assert re.search(rf"{bolt['count']}\s+Lightning Bolt", row), row
