#!/usr/bin/env bash
# Dumps of the production database, kept on the admin's machine (#107, #138).
#
#   scripts/backup.sh [dump]               dump production to KP_BACKUP_DIR and check it
#   scripts/backup.sh restore FILE SERVICE  load a dump into SERVICE's empty database
#   scripts/backup.sh install-timer         install and start the systemd user timer
#
# Postgres has no public address: every connection goes through Railway's SSH
# tunnel (`railway connect SERVICE --tunnel-only`), opened here and closed on exit.
# The database password goes to the Postgres tools in PGPASSWORD and is never
# printed. A dump holds every user's decks and the sign-in tables, so its folder
# is outside the repo and private to the admin.
#
# Settings (environment):
#   KP_BACKUP_DIR       where dumps go (default ~/.local/share/knowledge-pool/backups)
#   KP_BACKUP_KEEP      how many dumps to keep (default 14)
#   KP_BACKUP_SERVICE   the Postgres service `dump` reads (default Postgres-EU); it
#                       must be the one the app's JAC_DB_URL points at, or `dump` fails
#   KP_APP_SERVICE      the app's service (default knowledge-pool)
#   KP_BACKUP_SCHEDULE  install-timer's OnCalendar (default daily)
#   KP_RAILWAY_PROJECT, KP_RAILWAY_ENVIRONMENT  default to production, so the
#                       script works from any directory, linked or not
#   KP_PG_IMAGE         the image that runs pg_dump/pg_restore/psql when no local
#                       client is version 18 or newer (default postgres:18)
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO/scripts/backup.sh"
BACKUP_DIR="${KP_BACKUP_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/knowledge-pool/backups}"
KEEP="${KP_BACKUP_KEEP:-14}"
PROJECT="${KP_RAILWAY_PROJECT:-fb141f57-62d6-4897-98d5-bc6e145d915f}"
ENVIRONMENT="${KP_RAILWAY_ENVIRONMENT:-65957dce-6184-4fb6-948b-085ac9c5d6b1}"
APP_SERVICE="${KP_APP_SERVICE:-knowledge-pool}"
PG_IMAGE="${KP_PG_IMAGE:-postgres:18}"
PG_MAJOR=18
TUNNEL_WAIT=60

umask 077
TMP="$(mktemp -d)"
TUNNEL_PID=""
NOTIFY_ON_FAILURE=""
FAILURE="the script stopped early"

cleanup() {
    local status=$?
    if [ -n "$TUNNEL_PID" ]; then
        kill "$TUNNEL_PID" 2>/dev/null || true
        wait "$TUNNEL_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP"
    if [ "$status" -ne 0 ] && [ -n "$NOTIFY_ON_FAILURE" ]; then
        notify-send --urgency=critical "Knowledge Pool backup failed" \
            "$FAILURE. See: journalctl --user -u kp-backup" 2>/dev/null || true
    fi
    exit "$status"
}
trap cleanup EXIT

fail() {
    FAILURE="$1"
    echo "backup: $1" >&2
    exit 1
}

# pg TOOL ARGS... runs a Postgres client tool of version 18 or newer: the local
# one if it is new enough, otherwise from the postgres image (local packages
# lag the server). stdin and stdout pass through, so files never cross into
# the container.
pg() {
    local version
    version="$("$1" --version 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)"
    if [ -n "$version" ] && [ "$version" -ge "$PG_MAJOR" ]; then
        "$@"
    else
        docker run --rm -i --network host -e PGPASSWORD "$PG_IMAGE" "$@"
    fi
}

free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

port_open() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# app_uses SERVICE fails unless the app's JAC_DB_URL names SERVICE's private host,
# so a dump never quietly copies an old database after the app has moved on.
app_uses() {
    local service="$1" app_host service_host
    app_host="$(railway variable list --service "$APP_SERVICE" -p "$PROJECT" -e "$ENVIRONMENT" --json 2>/dev/null |
        python3 -c 'import json, sys, urllib.parse
print(urllib.parse.urlsplit(json.load(sys.stdin).get("JAC_DB_URL", "")).hostname or "")')" ||
        fail "could not read $APP_SERVICE's JAC_DB_URL from Railway (logged in? run: railway login)"
    service_host="$(railway variable list --service "$service" -p "$PROJECT" -e "$ENVIRONMENT" --json 2>/dev/null |
        python3 -c 'import json, sys; print(json.load(sys.stdin).get("PGHOST", ""))')" ||
        fail "could not read $service's variables from Railway"
    [ -n "$app_host" ] && [ "$app_host" = "$service_host" ] ||
        fail "$service is not the database the app uses: its JAC_DB_URL points at ${app_host:-nothing}; set KP_BACKUP_SERVICE"
}

# open_tunnel SERVICE reads SERVICE's user, password and database from Railway
# and opens the SSH tunnel to it on a free local port: sets PORT, PGUSER,
# PGPASSWORD (exported) and PGDATABASE.
open_tunnel() {
    local service="$1" vars
    vars="$(railway variable list --service "$service" -p "$PROJECT" -e "$ENVIRONMENT" --json 2>/dev/null)" ||
        fail "could not read $service's variables from Railway (logged in? run: railway login)"
    {
        read -r PGUSER
        read -r PGPASSWORD
        read -r PGDATABASE
    } < <(python3 -c 'import json, sys
v = json.load(sys.stdin)
for key in ("PGUSER", "PGPASSWORD", "PGDATABASE"):
    print(v.get(key, ""))' <<<"$vars") || fail "could not parse $service's variables"
    [ -n "$PGUSER" ] && [ -n "$PGPASSWORD" ] && [ -n "$PGDATABASE" ] ||
        fail "$service has no PGUSER, PGPASSWORD or PGDATABASE variable"
    export PGPASSWORD

    PORT="$(free_port)"
    railway connect "$service" --tunnel-only -P "$PORT" -p "$PROJECT" -e "$ENVIRONMENT" \
        </dev/null >"$TMP/tunnel.log" 2>&1 &
    TUNNEL_PID=$!
    local waited=0
    until port_open "$PORT"; do
        if ! kill -0 "$TUNNEL_PID" 2>/dev/null || [ "$waited" -ge "$TUNNEL_WAIT" ]; then
            show_tunnel_log
            fail "the tunnel to $service did not open"
        fi
        sleep 1
        waited=$((waited + 1))
    done
}

# The tunnel prints the connection details, password included: show its last
# lines with the password masked.
show_tunnel_log() {
    local line
    tail -n 5 "$TMP/tunnel.log" | while IFS= read -r line; do
        echo "  tunnel: ${line//"$PGPASSWORD"/********}" >&2
    done
}

connection() {
    echo --host=127.0.0.1 --port="$PORT" --username="$PGUSER" --dbname="$PGDATABASE"
}

cmd_dump() {
    NOTIFY_ON_FAILURE=1
    local folder
    mkdir -p "$BACKUP_DIR" 2>/dev/null && folder="$(cd "$BACKUP_DIR" && pwd -P)" ||
        fail "cannot create $BACKUP_DIR"
    case "$folder/" in
        "$(cd "$REPO" && pwd -P)/"*)
            rmdir "$BACKUP_DIR" 2>/dev/null || true
            fail "KP_BACKUP_DIR must be outside the repo: a dump holds every user's decks"
            ;;
    esac
    chmod 700 "$folder"

    local service="${KP_BACKUP_SERVICE:-Postgres-EU}"
    local name
    name="knowledge-pool-$(date -u +%Y-%m-%dT%H%M%SZ).dump"
    local partial="$TMP/$name.partial"

    app_uses "$service"
    open_tunnel "$service"
    # shellcheck disable=SC2046  # connection() is flags without spaces
    pg pg_dump $(connection) --format=custom --no-owner >"$partial" ||
        fail "pg_dump of $service failed"
    pg pg_restore --list <"$partial" >/dev/null ||
        fail "the new dump does not read back (pg_restore --list failed)"
    mv "$partial" "$folder/$name"
    echo "backup: wrote $folder/$name ($(du -h "$folder/$name" | cut -f1))"

    local old
    ls -1 "$folder" | grep -E '^knowledge-pool-.*\.dump$' | sort | head -n "-$KEEP" |
        while IFS= read -r old; do
            rm -f "$folder/$old"
            echo "backup: removed $old"
        done
}

cmd_restore() {
    [ "$#" -eq 2 ] || fail "usage: scripts/backup.sh restore FILE SERVICE"
    local file="$1" service="$2" typed
    [ -f "$file" ] || fail "no such dump: $file"
    pg pg_restore --list <"$file" >/dev/null || fail "$file does not read back (pg_restore --list failed)"

    echo "This loads $file into the database of Railway service '$service'."
    echo "It only runs into an empty database. Type the service name to go on:"
    read -r typed || true
    [ "$typed" = "$service" ] || fail "not confirmed; nothing was changed"

    open_tunnel "$service"
    local tables
    # shellcheck disable=SC2046
    tables="$(pg psql $(connection) --tuples-only --no-align --command \
        "select count(*) from pg_tables where schemaname not in ('pg_catalog', 'information_schema')")" ||
        fail "could not query $service"
    [ "$tables" = 0 ] ||
        fail "$service's database is not empty ($tables tables): restore only into a new Postgres service"

    local started=$SECONDS
    # shellcheck disable=SC2046
    pg pg_restore $(connection) --no-owner --exit-on-error <"$file" ||
        fail "pg_restore into $service failed; drop and recreate the service before trying again"
    echo "backup: restored $file into $service in $((SECONDS - started))s"
}

cmd_install_timer() {
    local units="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    mkdir -p "$units"
    sed -e "s|@SCRIPT@|$SCRIPT|" -e "s|@PATH@|$PATH|" \
        -e "s|@KEEP@|$KEEP|" -e "s|@BACKUP_DIR@|$BACKUP_DIR|" \
        "$REPO/scripts/systemd/kp-backup.service" >"$units/kp-backup.service"
    sed -e "s|@SCHEDULE@|${KP_BACKUP_SCHEDULE:-daily}|" \
        "$REPO/scripts/systemd/kp-backup.timer" >"$units/kp-backup.timer"
    systemctl --user daemon-reload
    systemctl --user enable --now kp-backup.timer
    systemctl --user list-timers kp-backup.timer --no-pager
}

case "${1:-dump}" in
    dump) cmd_dump ;;
    restore) shift; cmd_restore "$@" ;;
    install-timer) cmd_install_timer ;;
    *) fail "usage: scripts/backup.sh [dump | restore FILE SERVICE | install-timer]" ;;
esac
