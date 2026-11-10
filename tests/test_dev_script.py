"""scripts/dev.sh: one app per worktree, on its own port pair, with a pidfile."""

import os
import signal
import socket
import subprocess
from pathlib import Path
from urllib.request import urlopen

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "dev.sh"


@pytest.fixture
def env(fixture_catalog, tmp_path):
    return {
        **os.environ,
        "KP_DEV_DIR": str(tmp_path / "dev"),
        "KP_CATALOG": str(fixture_catalog),
        "JAC_DATA_PATH": str(tmp_path),
    }


@pytest.fixture(autouse=True)
def stop_server(env):
    yield
    if SCRIPT.exists():
        subprocess.run([str(SCRIPT), "down"], env=env, cwd=ROOT, timeout=60)


def dev(*args, env):
    return subprocess.run(
        [str(SCRIPT), *args], env=env, cwd=ROOT, capture_output=True, text=True, timeout=300
    )


def listening(port: int) -> bool:
    with socket.socket() as s:
        s.settimeout(1)
        return s.connect_ex(("127.0.0.1", port)) == 0


def healthy(port: int) -> bool:
    return urlopen(f"http://127.0.0.1:{port}/healthz", timeout=10).status == 200


def pid_of(env) -> int:
    return int((Path(env["KP_DEV_DIR"]) / "server.pid").read_text())


def test_up_serves_the_app_and_prints_its_urls(env):
    result = dev("up", env=env)
    assert result.returncode == 0, result.stdout + result.stderr
    port = int(dev("port", env=env).stdout)
    assert f"web: http://127.0.0.1:{port}" in result.stdout
    assert f"http://127.0.0.1:{port + 1}/mcp" in result.stdout
    assert f"log: {env['KP_DEV_DIR']}/server.log" in result.stdout
    assert healthy(port)


def test_up_twice_reuses_the_running_server(env):
    dev("up", env=env)
    port, pid = int(dev("port", env=env).stdout), pid_of(env)
    again = dev("up", env=env)
    assert again.returncode == 0
    assert int(dev("port", env=env).stdout) == port
    assert pid_of(env) == pid
    assert f"web: http://127.0.0.1:{port}" in again.stdout


def test_up_after_a_crash_starts_again(env):
    dev("up", env=env)
    pid = pid_of(env)
    os.killpg(pid, signal.SIGKILL)
    result = dev("up", env=env)
    assert result.returncode == 0, result.stdout + result.stderr
    assert pid_of(env) != pid
    assert healthy(int(dev("port", env=env).stdout))


def test_up_skips_a_taken_port(env):
    chosen = int(dev("port", env=env).stdout)
    with socket.socket() as blocker:
        blocker.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        blocker.bind(("127.0.0.1", chosen))
        blocker.listen()
        result = dev("up", env=env)
        assert result.returncode == 0, result.stdout + result.stderr
        port = int(dev("port", env=env).stdout)
        assert port != chosen
        assert healthy(port)


def test_down_frees_both_ports(env):
    dev("up", env=env)
    port = int(dev("port", env=env).stdout)
    assert dev("down", env=env).returncode == 0
    assert not (Path(env["KP_DEV_DIR"]) / "server.pid").exists()
    assert not listening(port) and not listening(port + 1)
    status = dev("status", env=env)
    assert status.returncode == 3
    assert "not running" in status.stdout


def test_status_when_not_running_exits_3(env):
    result = dev("status", env=env)
    assert result.returncode == 3
    assert "not running" in result.stdout
    assert dev("down", env=env).returncode == 0


def test_down_ignores_a_pidfile_naming_someone_elses_process(env):
    state = Path(env["KP_DEV_DIR"])
    state.mkdir(parents=True)
    stranger = subprocess.Popen(["sleep", "300"], start_new_session=True)
    try:
        (state / "server.pid").write_text(str(stranger.pid))
        (state / "port").write_text("8999")
        assert dev("down", env=env).returncode == 0
        assert stranger.poll() is None
        assert not (state / "server.pid").exists()
        assert not (state / "port").exists()
        assert dev("status", env=env).returncode == 3
    finally:
        stranger.kill()
        stranger.wait()
