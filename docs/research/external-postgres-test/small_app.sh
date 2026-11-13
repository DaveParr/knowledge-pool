#!/usr/bin/env bash
# usage: small.sh <JAC_DB_URL> <logname>  (re)starts the small two-user app on 18731
. $SCRATCH/env.sh; cd $S/app
[ -f $S/server.pid ] && kill $(cat $S/server.pid) 2>/dev/null; sleep 2
JAC_DB_URL="$1" nohup jac run --no-dev --host 127.0.0.1 -p 18731 -w 1 > $S/$2 2>&1 & echo $! > $S/server.pid
for i in $(seq 1 40); do curl -sf http://127.0.0.1:18731/healthz >/dev/null && break; sleep 1; done
curl -s -m 5 http://127.0.0.1:18731/healthz; echo
