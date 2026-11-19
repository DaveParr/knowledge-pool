"""scripts/backup.sh: the daily dump of the production database to the admin's
machine, and the restore of a dump into an empty Postgres (#138, decided in #107).

`railway`, `pg_dump`, `pg_restore`, `psql`, `notify-send` and `systemctl` are
fakes on PATH. The fake project has the app and two Postgres services, `Postgres`
and `Postgres-EU`; the app's JAC_DB_URL names Postgres-EU's host unless
FAKE_APP_DB_HOST says otherwise. The fake tunnel listens on the port it is given, the fake `pg_dump` writes a
small file, and each fake logs its arguments, so these tests run offline. The
real tunnel and Postgres 18 tools are tried in the drills."""

import os
import signal
import time
import re
import stat
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "backup.sh"
PASSWORD = "pw-do-not-print-0f3a"
ENCODED_PASSWORD = "pw%2Fencoded-0f3a"

FAKES = {
    "railway": f"""#!/usr/bin/env bash
echo "railway $*" >> "$FAKE_LOG"
case "$1" in
  variable)
    case "$*" in
      *"--service knowledge-pool "*)
        echo '{{"JAC_DB_URL":"postgresql://postgres:{PASSWORD}@'"${{FAKE_APP_DB_HOST:-postgres-eu.railway.internal}}"':5432/railway"}}' ;;
      *"--service Postgres "*) host=postgres.railway.internal ;;
      *) host=postgres-eu.railway.internal ;;
    esac
    [ -z "${{host:-}}" ] || echo '{{"PGUSER":"postgres","PGPASSWORD":"{PASSWORD}","PGDATABASE":"railway","PGHOST":"'"$host"'"}}' ;;
  service)
    echo '[{{"name":"knowledge-pool","source":{{"repo":"r","image":null}}}},
           {{"name":"Postgres","source":{{"image":"ghcr.io/railwayapp-templates/postgres-ssl:18"}}}},
           {{"name":"Postgres-EU","source":{{"image":"ghcr.io/railwayapp-templates/postgres-ssl:18"}}}}]' ;;
  connect)
    echo "Connection: postgresql://postgres:{PASSWORD}@127.0.0.1"
    echo "Connection: postgresql://postgres:{ENCODED_PASSWORD}@127.0.0.1"
    [ "${{FAKE_TUNNEL:-ok}}" = fail ] && exit 1
    echo $$ > "$FAKE_LOG.tunnel-pid"
    while [ "$#" -gt 0 ]; do [ "$1" = -P ] && port="$2"; shift; done
    exec python3 -c "import socket,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('127.0.0.1', $port)); s.listen(); time.sleep(600)" ;;
esac
""",
    "pg_dump": """#!/usr/bin/env bash
[ "$1" = --version ] && { echo "pg_dump (PostgreSQL) 18.1"; exit 0; }
echo "pg_dump $* password=${PGPASSWORD:+set}" >> "$FAKE_LOG"
[ "${FAKE_DUMP:-ok}" = fail ] && { echo "pg_dump: error: connection refused" >&2; exit 1; }
echo "PGDMP fake dump"
if [ "${FAKE_DUMP:-ok}" = slow ]; then touch "$FAKE_LOG.dumping"; sleep 30; fi
""",
    "pg_restore": """#!/usr/bin/env bash
[ "$1" = --version ] && { echo "pg_restore (PostgreSQL) 18.1"; exit 0; }
echo "pg_restore $* password=${PGPASSWORD:+set} input=$(cat)" >> "$FAKE_LOG"
[ "${FAKE_LIST:-ok}" = fail ] && { echo "pg_restore: error: input file is too short" >&2; exit 1; }
echo ";; Archive created"
""",
    "psql": """#!/usr/bin/env bash
[ "$1" = --version ] && { echo "psql (PostgreSQL) 18.1"; exit 0; }
echo "psql $*" >> "$FAKE_LOG"
echo "${FAKE_TABLES:-0}"
""",
    "notify-send": """#!/usr/bin/env bash
echo "notify-send $*" >> "$FAKE_LOG"
""",
    "systemctl": """#!/usr/bin/env bash
echo "systemctl $*" >> "$FAKE_LOG"
""",
}


@pytest.fixture
def env(tmp_path):
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for name, body in FAKES.items():
        path = bin_dir / name
        path.write_text(body)
        path.chmod(path.stat().st_mode | stat.S_IEXEC)
    return {
        **os.environ,
        "PATH": f"{bin_dir}:{os.environ['PATH']}",
        "FAKE_LOG": str(tmp_path / "calls.log"),
        "KP_BACKUP_DIR": str(tmp_path / "backups"),
        "XDG_CONFIG_HOME": str(tmp_path / "config"),
    }


def backup(*args, env, stdin=""):
    return subprocess.run(
        [str(SCRIPT), *args], env=env, cwd=ROOT, input=stdin,
        capture_output=True, text=True, timeout=60,
    )


def calls(env) -> str:
    log = Path(env["FAKE_LOG"])
    return log.read_text() if log.exists() else ""


def dumps(env) -> list[str]:
    return sorted(p.name for p in Path(env["KP_BACKUP_DIR"]).glob("*.dump"))


def test_dump_writes_a_dated_custom_format_file_and_checks_it(env):
    result = backup("dump", env=env)
    assert result.returncode == 0, result.stdout + result.stderr
    [name] = dumps(env)
    assert name.startswith("knowledge-pool-") and name.endswith(".dump")
    log = calls(env)
    assert "--tunnel-only" in log
    dump_call = next(line for line in log.splitlines() if line.startswith("pg_dump"))
    assert "--format=custom" in dump_call and "--no-owner" in dump_call
    assert "--dbname=railway" in dump_call and "password=set" in dump_call
    assert "pg_restore --list" in log and "input=PGDMP fake dump" in log
    assert "notify-send" not in log


def test_dump_is_the_default_command(env):
    assert backup(env=env).returncode == 0
    assert len(dumps(env)) == 1


def test_dump_keeps_only_the_newest_fourteen_by_default(env):
    folder = Path(env["KP_BACKUP_DIR"])
    folder.mkdir()
    old = [f"knowledge-pool-2026-01-{day:02d}T000000Z.dump" for day in range(1, 17)]
    for name in old:
        (folder / name).write_text("old")
    (folder / "notes.txt").write_text("not a dump")
    assert backup("dump", env=env).returncode == 0
    kept = dumps(env)
    assert len(kept) == 14
    assert kept[:13] == old[-13:]
    assert (folder / "notes.txt").exists()


def test_dump_keep_count_can_be_changed(env):
    folder = Path(env["KP_BACKUP_DIR"])
    folder.mkdir()
    for day in range(1, 20):
        (folder / f"knowledge-pool-2026-01-{day:02d}T000000Z.dump").write_text("old")
    assert backup("dump", env={**env, "KP_BACKUP_KEEP": "8"}).returncode == 0
    assert len(dumps(env)) == 8


def test_dump_failing_exits_non_zero_notifies_and_keeps_the_old_files(env):
    folder = Path(env["KP_BACKUP_DIR"])
    folder.mkdir()
    old = [f"knowledge-pool-2026-01-{day:02d}T000000Z.dump" for day in range(1, 10)]
    for name in old:
        (folder / name).write_text("old")
    result = backup("dump", env={**env, "FAKE_DUMP": "fail"})
    assert result.returncode != 0
    assert "notify-send" in calls(env)
    assert dumps(env) == old
    assert not list(folder.glob("*partial*"))


def test_dump_failing_its_check_exits_non_zero_and_is_not_kept(env):
    result = backup("dump", env={**env, "FAKE_LIST": "fail"})
    assert result.returncode != 0
    assert "notify-send" in calls(env)
    assert dumps(env) == []


def test_dump_whose_tunnel_does_not_open_exits_non_zero_and_notifies(env):
    result = backup("dump", env={**env, "FAKE_TUNNEL": "fail"})
    assert result.returncode != 0
    assert "tunnel" in result.stderr
    assert "notify-send" in calls(env)
    assert "pg_dump --" not in calls(env)


def test_dump_never_prints_the_password(env):
    for extra in ({}, {"FAKE_TUNNEL": "fail"}, {"FAKE_DUMP": "fail"}):
        result = backup("dump", env={**env, **extra})
        output = result.stdout + result.stderr
        assert PASSWORD not in output
        assert ENCODED_PASSWORD not in output


def test_dump_refuses_a_folder_inside_the_repo(env):
    result = backup("dump", env={**env, "KP_BACKUP_DIR": str(ROOT / "backups")})
    assert result.returncode != 0
    assert "outside the repo" in result.stderr
    assert not (ROOT / "backups").exists()


def test_dump_refuses_a_nested_folder_inside_the_repo_without_creating_it(env):
    result = backup("dump", env={**env, "KP_BACKUP_DIR": str(ROOT / "nested" / "backups")})
    assert result.returncode != 0
    assert not (ROOT / "nested").exists()


def test_dump_files_are_private_to_the_admin(env):
    assert backup("dump", env=env).returncode == 0
    folder = Path(env["KP_BACKUP_DIR"])
    assert stat.S_IMODE(folder.stat().st_mode) == 0o700
    [name] = dumps(env)
    assert stat.S_IMODE((folder / name).stat().st_mode) == 0o600


def test_restore_loads_a_dump_into_an_empty_database(env, tmp_path):
    dump = tmp_path / "chosen.dump"
    dump.write_text("PGDMP chosen")
    result = backup("restore", str(dump), "Postgres-EU", env=env, stdin="Postgres-EU\n")
    assert result.returncode == 0, result.stdout + result.stderr
    log = calls(env)
    assert "connect Postgres-EU --tunnel-only" in log
    restore_call = next(
        line for line in log.splitlines() if line.startswith("pg_restore") and "--list" not in line
    )
    assert "--no-owner" in restore_call and "--exit-on-error" in restore_call
    assert "--dbname=railway" in restore_call and "input=PGDMP chosen" in restore_call


def test_restore_refuses_a_database_that_already_has_tables(env, tmp_path):
    dump = tmp_path / "chosen.dump"
    dump.write_text("PGDMP chosen")
    result = backup(
        "restore", str(dump), "Postgres", env={**env, "FAKE_TABLES": "12"}, stdin="Postgres\n"
    )
    assert result.returncode != 0
    assert "not empty" in result.stderr
    assert not any(
        line.startswith("pg_restore") and "--list" not in line for line in calls(env).splitlines()
    )


def test_restore_needs_the_service_name_typed_back(env, tmp_path):
    dump = tmp_path / "chosen.dump"
    dump.write_text("PGDMP chosen")
    result = backup("restore", str(dump), "Postgres-EU", env=env, stdin="yes\n")
    assert result.returncode != 0
    assert "--tunnel-only" not in calls(env)


def test_dump_reads_the_database_the_app_uses(env):
    assert backup("dump", env=env).returncode == 0
    assert "connect Postgres-EU --tunnel-only" in calls(env)
    calls_path = Path(env["FAKE_LOG"])
    calls_path.unlink()
    moved = {**env, "FAKE_APP_DB_HOST": "postgres.railway.internal"}
    result = backup("dump", env=moved)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "connect Postgres --tunnel-only" in calls(env)


def test_dump_refuses_a_named_service_the_app_does_not_use(env):
    result = backup("dump", env={**env, "KP_BACKUP_SERVICE": "Postgres"})
    assert result.returncode != 0
    assert "not the database the app uses" in result.stderr
    assert "postgres-eu.railway.internal" in result.stderr
    assert "notify-send" in calls(env)
    assert "--tunnel-only" not in calls(env)
    assert PASSWORD not in result.stdout + result.stderr


def test_dump_fails_when_no_service_has_the_apps_database_host(env):
    result = backup("dump", env={**env, "FAKE_APP_DB_HOST": "gone.railway.internal"})
    assert result.returncode != 0
    assert "gone.railway.internal" in result.stderr
    assert "notify-send" in calls(env)
    assert "--tunnel-only" not in calls(env)


@pytest.mark.parametrize("keep", ["0", "-3", "many"])
def test_dump_refuses_a_keep_count_below_one_and_deletes_nothing(env, keep):
    folder = Path(env["KP_BACKUP_DIR"])
    folder.mkdir()
    (folder / "knowledge-pool-2026-01-01T000000Z.dump").write_text("old")
    result = backup("dump", env={**env, "KP_BACKUP_KEEP": keep})
    assert result.returncode != 0
    assert "KP_BACKUP_KEEP" in result.stderr
    assert dumps(env) == ["knowledge-pool-2026-01-01T000000Z.dump"]


def test_install_timer_writes_both_units_and_enables_the_timer(env):
    result = backup("install-timer", env={**env, "KP_BACKUP_SCHEDULE": "weekly"})
    assert result.returncode == 0, result.stdout + result.stderr
    units = Path(env["XDG_CONFIG_HOME"]) / "systemd" / "user"
    service = (units / "kp-backup.service").read_text()
    assert f'ExecStart="{SCRIPT}" dump' in service
    assert f'Environment="KP_BACKUP_DIR={env["KP_BACKUP_DIR"]}"' in service
    assert not re.search(r"@[A-Z_]+@", service)
    timer = (units / "kp-backup.timer").read_text()
    assert "OnCalendar=weekly" in timer and "Persistent=true" in timer
    assert "systemctl --user enable --now kp-backup.timer" in calls(env)


def test_install_timer_refuses_a_value_a_unit_cannot_hold(env, tmp_path):
    result = backup("install-timer", env={**env, "KP_BACKUP_DIR": str(tmp_path / "100%")})
    assert result.returncode != 0
    assert "KP_BACKUP_DIR" in result.stderr
    assert "systemctl" not in calls(env)


@pytest.mark.parametrize("sig", [signal.SIGTERM, signal.SIGHUP, signal.SIGINT])
def test_dump_killed_midway_closes_the_tunnel_and_leaves_no_partial(env, sig):
    run = subprocess.Popen(
        [str(SCRIPT), "dump"], env={**env, "FAKE_DUMP": "slow"}, cwd=ROOT,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
    )
    dumping = Path(env["FAKE_LOG"] + ".dumping")
    deadline = time.monotonic() + 30
    while not dumping.exists():
        assert time.monotonic() < deadline, "the fake dump never started"
        time.sleep(0.1)
    tunnel = int(Path(env["FAKE_LOG"] + ".tunnel-pid").read_text())
    os.killpg(run.pid, sig)  # as a terminal's Ctrl-C or hangup does
    assert run.wait(timeout=30) != 0
    time.sleep(0.5)
    with pytest.raises(ProcessLookupError):
        os.kill(tunnel, 0)
    assert not list(Path(env["KP_BACKUP_DIR"]).glob("*partial*"))
    assert dumps(env) == []
