"""The front door as a real process (`mcp_server.jac` over HTTP): it starts Jac's
server for the page as a child, hands out the page through itself, runs the page's
deck calls itself, and exits if the child dies (ADR 0004)."""

import json
import os
import socket
import subprocess
import sys
import time
from contextlib import contextmanager
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import Request, urlopen

import pytest

import front_door
from tests.hosted_settings import HOSTED_SETTINGS

ROOT = Path(__file__).resolve().parent.parent
LOOPBACK = front_door.LOOPBACK


_free_port = front_door.free_port


def _get(url: str, data: bytes | None = None, headers: dict | None = None) -> tuple[int, bytes]:
    try:
        with urlopen(Request(url, data=data, headers=headers or {}), timeout=30) as reply:
            return reply.status, reply.read()
    except HTTPError as refused:
        return refused.code, refused.read()


@contextmanager
def _running(fixture_catalog, jac_db_url, **settings: str):
    """The front door as a process on a free port, once it answers its health
    path; `settings` go into its environment on top of local mode's."""
    port, upstream_port = _free_port(), _free_port()
    env = {
        **os.environ, "KP_CATALOG": str(fixture_catalog), "JAC_DB_URL": jac_db_url, "KP_MODE": "local",
        "KP_TRANSPORT": "http", "KP_HTTP_PORT": str(port), "KP_UPSTREAM_PORT": str(upstream_port), **settings,
    }
    log = ROOT / "test-artifacts" / "front_door_process.log"
    log.parent.mkdir(exist_ok=True)
    with log.open("w") as out:
        proc = subprocess.Popen(
            [sys.executable, "run", "--no-serve", "mcp_server.jac"], cwd=ROOT, env=env,
            stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT,
        )
        try:
            for _ in range(240):
                if proc.poll() is not None:
                    pytest.fail(f"the front door exited with {proc.returncode}: see {log}")
                try:
                    if _get(f"http://{LOOPBACK}:{port}/healthz")[0] == 200:
                        break
                except OSError:
                    time.sleep(0.5)
            else:
                pytest.fail(f"the front door did not answer: see {log}")
            yield proc, f"http://{LOOPBACK}:{port}", upstream_port
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=30)
            except subprocess.TimeoutExpired:
                proc.kill()


@pytest.fixture
def front_door(fixture_catalog, jac_db_url):
    with _running(fixture_catalog, jac_db_url) as running:
        yield running


@pytest.mark.skip("probe")
def test_hosted_mode_starts_with_its_settings_and_answers_health_but_no_data_call(fixture_catalog, jac_db_url):
    with _running(fixture_catalog, jac_db_url, KP_MODE="hosted", **HOSTED_SETTINGS, KP_TRANSPORT="http") as (_, base, _):
        reply = _get(base + "/healthz")
        assert reply == (200, b"ok")
        refused = _get(base + "/walker/ListDecks", b"{}", {"Origin": base, "Content-Type": "application/json"})
        assert refused[0] == 401
        # Nor the page: served with no caller, its first data call gets a 401 and
        # Jac's client, holding no Jac token, reloads the page for ever.
        assert _get(base + "/")[0] == 401


def test_page_loads_through_the_front_door_and_a_deck_can_be_read(front_door):
    _, base, _ = front_door
    status, page = _get(base + "/")
    assert status == 200 and b'<div id="root">' in page
    headers = {"Origin": base, "Content-Type": "application/json"}
    made = _get(base + "/walker/CreateDeck", b'{"name": "Through the door"}', headers)
    assert made[0] == 200
    listed = _get(base + "/walker/ListDecks", b"{}", headers)
    assert listed[0] == 200
    assert [d["name"] for d in json.loads(listed[1])["data"]["reports"][0]] == ["Through the door"]
    assert _get(base + "/docs")[0] == 404 and _get(base + "/walkers")[0] == 404


def test_jacs_server_for_the_page_refuses_deck_calls_without_a_jac_token(front_door):
    _, _, upstream_port = front_door
    direct = f"http://{LOOPBACK}:{upstream_port}"
    assert _get(direct + "/")[0] == 200
    assert _get(direct + "/walker/ListDecks", b"{}", {"Content-Type": "application/json"})[0] == 401
    assert _get(direct + "/function/list_formats", b"{}", {"Content-Type": "application/json"})[0] == 401


def test_the_front_door_exits_when_jacs_server_dies(front_door):
    proc, _, upstream_port = front_door
    child = next(
        int(pid) for pid in os.listdir("/proc") if pid.isdigit()
        and f"--port\0{upstream_port}\0" in Path(f"/proc/{pid}/cmdline").read_text(errors="ignore")
    )
    os.kill(child, 9)
    assert proc.wait(timeout=30) != 0


def test_jacs_server_is_set_up_as_the_front_doors_child():
    """One worker, docs and graph off, registration off (`jac.toml`)."""
    from jaclang.server.settings import ServeSettings

    settings = ServeSettings.load(base_path=str(ROOT))
    assert (settings.workers.count, settings.docs_enabled, settings.graph_enabled) == (1, False, False)
    assert settings.auth.registration.enabled is False


def _listening(port: int) -> bool:
    with socket.socket() as s:
        s.settimeout(1)
        return s.connect_ex((LOOPBACK, port)) == 0


def test_stopping_the_front_door_stops_jacs_server_with_it(front_door):
    proc, _, upstream_port = front_door
    assert _listening(upstream_port)
    proc.terminate()
    proc.wait(timeout=30)
    for _ in range(30):
        if not _listening(upstream_port):
            return
        time.sleep(0.5)
    pytest.fail(f"Jac's server for the page still listens on {upstream_port} after the front door stopped")
