#!/usr/bin/env bash
# Run the app for this worktree: the web app and the MCP server (over HTTP) as two
# processes in one process group, on their own port pair, with a pidfile. Both use
# this worktree's own database (or JAC_DB_URL when set). When either process
# exits, the other is stopped too. Never kills by name; `down` signals the
# recorded group only.
#
#   scripts/dev.sh up|down|status|port
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SLUG="$(basename "$REPO")"
STATE="${KP_DEV_DIR:-$REPO/.jac/dev}"
PIDFILE="$STATE/server.pid"
PORTFILE="$STATE/port"
LOG="$STATE/server.log"
export KP_CATALOG="${KP_CATALOG:-$REPO/data/catalog.sqlite}"
export JAC_STRICT_PERMISSIONS=1

port_taken() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

is_running() {
    [ -f "$PIDFILE" ] || return 1
    local pgid
    pgid="$(cat "$PIDFILE")"
    [ -n "$pgid" ] && group_alive "$pgid"
}

# True while the group holds a live (non-zombie) mcp_server.jac process, so a stale
# pidfile whose number was reused by someone else's group is never treated as ours.
group_alive() {
    ps -eo pgid=,stat=,args= 2>/dev/null |
        awk -v g="$1" '$1 == g && $2 !~ /^Z/ && index($0, "mcp_server.jac") { f = 1 } END { exit !f }'
}

choose_port() {
    if [ -n "${KP_DEV_PORT:-}" ]; then
        echo "$KP_DEV_PORT"
        return
    fi
    local p
    p=$((8100 + 2 * ($(printf %s "$REPO" | cksum | cut -d' ' -f1) % 400)))
    while port_taken "$p" || port_taken $((p + 1)); do
        p=$((p + 2))
    done
    echo "$p"
}

current_port() {
    if is_running && [ -f "$PORTFILE" ]; then
        cat "$PORTFILE"
    else
        choose_port
    fi
}

print_urls() {
    local p
    p="$(cat "$PORTFILE")"
    echo "web: http://127.0.0.1:$p"
    echo "mcp: claude mcp add --transport http knowledge-pool-$SLUG http://127.0.0.1:$((p + 1))/mcp"
    echo "log: $LOG"
}

# Build the catalogue at $KP_CATALOG from the shared download cache when it is
# missing or out of date (downloads only if the cached files are old or absent).
ensure_catalogue() {
    if ! (cd "$REPO" && jac x catalogue); then
        echo "dev.sh: could not build the catalogue (see above)" >&2
        return 1
    fi
}

cmd_up() {
    if is_running; then
        print_urls
        return 0
    fi
    rm -f "$PIDFILE" "$PORTFILE"
    mkdir -p "$STATE"
    ensure_catalogue || return 1
    local p
    p="$(choose_port)"
    echo "$p" >"$PORTFILE"
    cd "$REPO" || return 1
    setsid bash -c '
        jac run --no-dev --host 127.0.0.1 --port "$1" main.jac &
        KP_TRANSPORT=http KP_HTTP_PORT="$2" jac run --no-serve mcp_server.jac &
        wait -n
        kill 0' dev.sh "$p" $((p + 1)) >>"$LOG" 2>&1 &
    echo $! >"$PIDFILE"

    local i
    for ((i = 0; i < 120; i++)); do
        if curl -fs -o /dev/null --max-time 2 "http://127.0.0.1:$p/healthz" && port_taken $((p + 1)); then
            print_urls
            return 0
        fi
        if ! is_running; then
            break
        fi
        sleep 1
    done
    echo "server did not come up; last of $LOG:" >&2
    tail -n 30 "$LOG" >&2
    cmd_down
    return 1
}

cmd_down() {
    if ! [ -f "$PIDFILE" ]; then
        return 0
    fi
    local pgid p i
    pgid="$(cat "$PIDFILE")"
    p="$(cat "$PORTFILE" 2>/dev/null || true)"
    if [ -n "$pgid" ] && group_alive "$pgid"; then
        kill -TERM -- "-$pgid" 2>/dev/null
        for ((i = 0; i < 20; i++)); do
            if ! group_alive "$pgid" &&
                { [ -z "$p" ] || { ! port_taken "$p" && ! port_taken $((p + 1)); }; }; then
                break
            fi
            sleep 0.5
        done
        kill -KILL -- "-$pgid" 2>/dev/null || true
    fi
    rm -f "$PIDFILE" "$PORTFILE"
}

cmd_status() {
    if is_running && [ -f "$PORTFILE" ]; then
        print_urls
    else
        echo "not running"
        return 3
    fi
}

case "${1:-}" in
    up) cmd_up ;;
    down) cmd_down ;;
    status) cmd_status ;;
    port) current_port ;;
    *)
        echo "usage: scripts/dev.sh up|down|status|port" >&2
        exit 2
        ;;
esac
