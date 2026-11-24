"""The upstream child: Jac's server for the web page, run as the front door's
child (ADR 0004).

It starts it on 127.0.0.1 only, stops it (at exit, on SIGTERM) and watches it:
if the child dies while the front door serves, the front door exits. Nothing
here knows who is asking or what is served; the front door (`front_door.jac`)
forwards the page and its static files to the URL `start_upstream` returns.
"""

import os;
import signal;
import socket;
import subprocess;
import sys;
import threading;
import time;
import atexit;
import from graph_runner { APP_DIR }

glob LOOPBACK: str = "127.0.0.1",
     UPSTREAM_BOOT_S: float = 120.0,
     STOPPING: threading.Event = threading.Event();

"""A TCP port nothing listens on now."""
def free_port -> int {
    with socket.socket() as s {
        s.bind((LOOPBACK, 0));
        return s.getsockname()[1];
    }
}

"""Start Jac's server for the page as a child, on 127.0.0.1 only (`port`;
a free one when 0). One worker, docs and graph off and registration off come
from `jac.toml`. Returns the child and its URL once it answers, or raises.

The child's output goes to stderr, or, when `to_stdout` (hosted mode, `log_setup.jac`), to
stdout, where a host reads a plain line as routine."""
def start_upstream(port: int = 0, to_stdout: bool = False) -> tuple[subprocess.Popen, str] {  # jac:ignore[W1036]
    port = port or free_port();
    out = sys.stdout if to_stdout else sys.stderr;
    child = subprocess.Popen(
        [sys.executable, "run", "--no-dev", "--host", LOOPBACK, "--port", str(port), "main.jac"],
        cwd=APP_DIR, stdin=subprocess.DEVNULL, stdout=out, stderr=out
    );
    atexit.register(stop_upstream, child);
    url = f"http://{LOOPBACK}:{port}";
    deadline = time.monotonic() + UPSTREAM_BOOT_S;
    while time.monotonic() < deadline {
        if child.poll() is not None {
            raise RuntimeError(f"Jac's server for the page exited with code {child.returncode} at start.");
        }
        try {
            with socket.create_connection((LOOPBACK, port), timeout=1) {
                return (child, url);
            }
        } except OSError {
            time.sleep(0.5);
        }
    }
    stop_upstream(child);
    raise RuntimeError(f"Jac's server for the page did not listen on {url} within {UPSTREAM_BOOT_S:.0f}s.");
}

"""Stop the child, if it still runs."""
def stop_upstream(child: subprocess.Popen) {  # jac:ignore[W1036]
    if child.poll() is None {
        child.terminate();
        try {
            child.wait(timeout=10);
        } except subprocess.TimeoutExpired {
            child.kill();
        }
    }
}

"""Stop the child when the front door is told to stop (SIGTERM). Uvicorn shuts down
and then re-raises the signal with the handler it found, which by default ends the
process without running `finally` or `atexit`; this handler is the one it finds."""
def stop_child_on_sigterm(child: subprocess.Popen) {  # jac:ignore[W1036]
    def stop(signum: int, frame: object) {  # jac:ignore[W1036,W1037,W2003]
        expect_upstream_to_stop();
        stop_upstream(child);
        raise SystemExit(128 + signum);
    }
    signal.signal(signal.SIGTERM, stop);
}

"""If the child dies while the front door serves, the front door exits (the
page would be gone, and a restart policy can bring both back)."""
def exit_when_upstream_dies(child: subprocess.Popen) {  # jac:ignore[W1036]
    def watch {
        code = child.wait();
        if not STOPPING.is_set() {
            sys.stderr.write(f"Jac's server for the page died with code {code}: the front door exits.\n");
            sys.stderr.flush();
            os._exit(1);
        }
    }
    threading.Thread(target=watch, daemon=True).start();
}

"""Tell the watcher that the child's end is expected."""
def expect_upstream_to_stop {
    STOPPING.set();
}
