"""scripts/backup.sh: the weekly dump of the production database to the admin's
machine, and the restore of a dump into an empty Postgres (#138, decided in #107).

`railway`, `pg_dump`, `pg_restore`, `psql` and `notify-send` are fakes on PATH:
the fake tunnel listens on the port it is given, the fake `pg_dump` writes a
small file, and each fake logs its arguments, so these tests run offline. The
real tunnel and Postgres 18 tools are tried in the drills."""

import os
import stat
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts" / "backup.sh"
PASSWORD = "pw-do-not-print-0f3a"

FAKES = {
    "railway": f"""#!/usr/bin/env bash
echo "railway $*" >> "$FAKE_LOG"
case "$1" in
  variable)
    echo '{{"PGUSER":"postgres","PGPASSWORD":"{PASSWORD}","PGDATABASE":"railway"}}' ;;
  connect)
    echo "Connection: postgresql://postgres:{PASSWORD}@127.0.0.1"
    [ "${{FAKE_TUNNEL:-ok}}" = fail ] && exit 1
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


def test_dump_keeps_only_the_newest_fourteen(env):
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


def test_a_failed_dump_exits_non_zero_notifies_and_keeps_the_old_files(env):
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


def test_a_dump_that_fails_its_check_exits_non_zero_and_is_not_kept(env):
    result = backup("dump", env={**env, "FAKE_LIST": "fail"})
    assert result.returncode != 0
    assert "notify-send" in calls(env)
    assert dumps(env) == []


def test_a_tunnel_that_does_not_open_exits_non_zero_and_notifies(env):
    result = backup("dump", env={**env, "FAKE_TUNNEL": "fail"})
    assert result.returncode != 0
    assert "tunnel" in result.stderr
    assert "notify-send" in calls(env)
    assert "pg_dump --" not in calls(env)


def test_the_password_never_reaches_the_output(env):
    for extra in ({}, {"FAKE_TUNNEL": "fail"}, {"FAKE_DUMP": "fail"}):
        result = backup("dump", env={**env, **extra})
        assert PASSWORD not in result.stdout + result.stderr


def test_dump_refuses_a_folder_inside_the_repo(env):
    result = backup("dump", env={**env, "KP_BACKUP_DIR": str(ROOT / "backups")})
    assert result.returncode != 0
    assert "outside the repo" in result.stderr
    assert not (ROOT / "backups").exists()


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
