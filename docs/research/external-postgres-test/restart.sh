#!/usr/bin/env bash
# usage: restart.sh <JAC_DB_URL>   restarts web (18741) and MCP (18742) in the copy
. $SCRATCH/env.sh; cd $S/copy
export JAC_DB_URL="$1"
for p in web mcp; do [ -f $S/$p.pid ] && kill $(cat $S/$p.pid) 2>/dev/null; done; sleep 3
for p in web mcp; do [ -f $S/$p.pid ] && kill -9 $(cat $S/$p.pid) 2>/dev/null; done
nohup jac run --no-dev --host 127.0.0.1 -p 18741 -w 1 > $S/web.log 2>&1 & echo $! > $S/web.pid
KP_WEB=0 KP_TRANSPORT=http KP_HTTP_PORT=18742 nohup jac run mcp_server.jac > $S/mcp.log 2>&1 & echo $! > $S/mcp.pid
for i in $(seq 1 150); do curl -sf http://127.0.0.1:18741/healthz >/dev/null && break; sleep 1; done
for i in $(seq 1 60); do curl -s -o /dev/null http://127.0.0.1:18742/mcp && break; sleep 1; done
curl -s http://127.0.0.1:18741/healthz; echo
