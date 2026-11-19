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
#   KP_BACKUP_SERVICE   the Postgres service `dump` reads. Unset, `dump` finds the
#                       service whose private host the app's JAC_DB_URL names; set,
#                       it must be that service, or `dump` fails
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
PARTIAL=""
NOTIFY_ON_FAILURE=""
FAILURE="the script stopped early"

cleanup() {
    local status=$?
    if [ -n "$TUNNEL_PID" ]; then
        kill -- "-$TUNNEL_PID" 2>/dev/null || kill "$TUNNEL_PID" 2>/dev/null || true
        wait "$TUNNEL_PID" 2>/dev/null || true
    fi
    rm -rf "$TMP"
    [ -z "$PARTIAL" ] || rm -f "$PARTIAL"
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

# railway_vars SERVICE KEY... prints SERVICE's variables KEY..., one per line.
railway_vars() {
    local service="$1"
    shift
    railway variable list --service "$service" -p "$PROJECT" -e "$ENVIRONMENT" --json 2>/dev/null |
        python3 -c 'import json, sys
v = json.load(sys.stdin)
for key in sys.argv[1:]:
    print(v.get(key, ""))' "$@"
}

url_host() {
    python3 -c 'import sys, urllib.parse; print(urllib.parse.urlsplit(sys.stdin.read().strip()).hostname or "")'
}

# find_app_database sets DB_SERVICE to the Postgres service whose private host the
# app's JAC_DB_URL names (or checks KP_BACKUP_SERVICE is it), so a dump never
# quietly copies an old database after the app has moved to a new one.
find_app_database() {
    local app_host name candidates
    app_host="$(railway_vars "$APP_SERVICE" JAC_DB_URL | url_host)" ||
        fail "could not read $APP_SERVICE's JAC_DB_URL from Railway (logged in? run: railway login)"
    [ -n "$app_host" ] || fail "$APP_SERVICE has no JAC_DB_URL"
    if [ -n "${KP_BACKUP_SERVICE:-}" ]; then
        candidates="$KP_BACKUP_SERVICE"
    else
        candidates="$(railway service list -p "$PROJECT" -e "$ENVIRONMENT" --json 2>/dev/null |
            python3 -c 'import json, sys
for s in json.load(sys.stdin):
    if "postgres" in ((s.get("source") or {}).get("image") or ""):
        print(s["name"])')" || fail "could not list the project's services"
    fi
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if [ "$(railway_vars "$name" PGHOST)" = "$app_host" ]; then
            DB_SERVICE="$name"
            return
        fi
    done <<<"$candidates"
    if [ -n "${KP_BACKUP_SERVICE:-}" ]; then
        fail "$KP_BACKUP_SERVICE is not the database the app uses: its JAC_DB_URL points at $app_host"
    fi
    fail "no Postgres service has the host the app's JAC_DB_URL points at ($app_host)"
}

# open_tunnel SERVICE reads SERVICE's user, password and database from Railway
# and opens the SSH tunnel to it on a free local port. Sets CONN (the flags the
# Postgres tools connect with) and exports PGPASSWORD.
open_tunnel() {
    local service="$1" user database
    {
        read -r user
        read -r PGPASSWORD
        read -r database
    } < <(railway_vars "$service" PGUSER PGPASSWORD PGDATABASE) ||
        fail "could not read $service's variables from Railway (logged in? run: railway login)"
    [ -n "$user" ] && [ -n "$PGPASSWORD" ] && [ -n "$database" ] ||
        fail "$service has no PGUSER, PGPASSWORD or PGDATABASE variable"
    export PGPASSWORD

    local port waited=0
    port="$(free_port)"
    CONN=(--host=127.0.0.1 --port="$port" --username="$user" --dbname="$database")
    # Its own process group, so cleanup stops anything the CLI starts.
    setsid railway connect "$service" --tunnel-only -P "$port" -p "$PROJECT" -e "$ENVIRONMENT" \
        </dev/null >"$TMP/tunnel.log" 2>&1 &
    TUNNEL_PID=$!
    until port_open "$port"; do
        if ! kill -0 "$TUNNEL_PID" 2>/dev/null || [ "$waited" -ge "$TUNNEL_WAIT" ]; then
            show_tunnel_log
            fail "the tunnel to $service did not open"
        fi
        sleep 1
        waited=$((waited + 1))
    done
}

# The tunnel prints the connection details, password included: show its last
# lines with the password masked, and any URL's password too (it may be
# percent-encoded there).
show_tunnel_log() {
    local line
    tail -n 5 "$TMP/tunnel.log" | while IFS= read -r line; do
        echo "  tunnel: ${line//"$PGPASSWORD"/********}"
    done | sed -E 's#(://[^:/@[:space:]]*):[^@[:space:]]*@#\1:********@#g' >&2
}

require_keep() {
    [[ "$KEEP" =~ ^[1-9][0-9]*$ ]] || fail "KP_BACKUP_KEEP must be a whole number of at least 1, not '$KEEP'"
}

cmd_dump() {
    NOTIFY_ON_FAILURE=1
    require_keep
    local folder
    folder="$(realpath -m "$BACKUP_DIR")"
    case "$folder/" in
        "$(realpath "$REPO")/"*)
            fail "KP_BACKUP_DIR must be outside the repo: a dump holds every user's decks" ;;
    esac
    mkdir -p "$folder" && chmod 700 "$folder" || fail "cannot create $folder"

    local name
    name="knowledge-pool-$(date -u +%Y-%m-%dT%H%M%SZ).dump"
    # Written beside its final name, so the rename that marks it good is atomic.
    PARTIAL="$folder/.$name.partial"

    find_app_database
    open_tunnel "$DB_SERVICE"
    pg pg_dump "${CONN[@]}" --format=custom --no-owner >"$PARTIAL" ||
        fail "pg_dump of $DB_SERVICE failed"
    pg pg_restore --list <"$PARTIAL" >/dev/null ||
        fail "the new dump does not read back (pg_restore --list failed)"
    mv "$PARTIAL" "$folder/$name"
    PARTIAL=""
    echo "backup: wrote $folder/$name from $DB_SERVICE ($(du -h "$folder/$name" | cut -f1))"

    local old
    find "$folder" -maxdepth 1 -name 'knowledge-pool-*.dump' -printf '%f\n' | sort | head -n "-$KEEP" |
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
    tables="$(pg psql "${CONN[@]}" --tuples-only --no-align --command \
        "select count(*) from pg_tables where schemaname not in ('pg_catalog', 'information_schema')")" ||
        fail "could not query $service"
    [ "$tables" = 0 ] ||
        fail "$service's database is not empty ($tables tables): restore only into a new Postgres service"

    local started=$SECONDS
    pg pg_restore "${CONN[@]}" --no-owner --exit-on-error <"$file" ||
        fail "pg_restore into $service failed; drop and recreate the service before trying again"
    echo "backup: restored $file into $service in $((SECONDS - started))s"
}

# unit_value NAME VALUE prints VALUE if it can go into a unit file as it is:
# no sed delimiter, systemd specifier, quote, backslash or newline.
unit_value() {
    case "$2" in
        *[\|\&%\"\\]* | *$'\n'*) fail "$1 cannot go into a systemd unit as it is: $2" ;;
    esac
    printf '%s' "$2"
}

cmd_install_timer() {
    require_keep
    local units="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user" script path keep dir schedule
    script="$(unit_value "the script path" "$SCRIPT")"
    path="$(unit_value PATH "$PATH")"
    keep="$(unit_value KP_BACKUP_KEEP "$KEEP")"
    dir="$(unit_value KP_BACKUP_DIR "$(realpath -m "$BACKUP_DIR")")"
    schedule="$(unit_value KP_BACKUP_SCHEDULE "${KP_BACKUP_SCHEDULE:-daily}")"
    mkdir -p "$units"
    sed -e "s|@SCRIPT@|$script|" -e "s|@PATH@|$path|" -e "s|@KEEP@|$keep|" -e "s|@BACKUP_DIR@|$dir|" \
        "$REPO/scripts/systemd/kp-backup.service" >"$units/kp-backup.service"
    sed -e "s|@SCHEDULE@|$schedule|" "$REPO/scripts/systemd/kp-backup.timer" >"$units/kp-backup.timer"
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
