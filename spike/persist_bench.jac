"""S02 benchmark: how long saving catalogue cards through Jac's persistence takes.

    KP_N=3000 KP_MODE=bulk uv run jac run spike/persist_bench.jac

KP_MODE=each attaches every card to `root` as it is made; KP_MODE=bulk builds
them under a detached hub first and attaches the hub once; KP_MODE=buckets
spreads them over hub -> bucket nodes of 100 cards each, then attaches the hub. Run with a clean
`.jac/data`. The time includes the commit when the program exits only if you
time the whole command, so the script prints build time and the shell times
the rest.
"""

import os;
import sqlite3;
import json;
import time;
import from spike.synergy { Card, Catalog }

with entry:__main__ {
    n = int(os.environ.get("KP_N", "1000"));
    mode = os.environ.get("KP_MODE", "bulk");
    con = sqlite3.connect("data/catalog.sqlite");
    rows = con.execute(
        "SELECT oracle_id, name, mana_value, types, text, legalities FROM cards LIMIT ?", (n, )
    ).fetchall();
    t0 = time.perf_counter();
    hub = Catalog();
    bucket = Catalog();
    in_bucket = 0;
    for row in rows {
        card = Card(
            oracle_id=row[0] as str,
            name=row[1] as str,
            mana_value=row[2] as float,
            types=json.loads(row[3] as str) as list[str],
            text=row[4] as str,
            legal=json.loads(row[5] as str) as dict[str, str]
        );
        if mode == "each" {
            root ++> card;
        } elif mode == "buckets" {
            if in_bucket == 0 {
                bucket = Catalog();
                hub ++> bucket;
            }
            bucket ++> card;
            in_bucket = (in_bucket + 1) % 100;
        } else {
            hub ++> card;
        }
    }
    if mode != "each" {
        root ++> hub;
    }
    print(f"BUILT {len(rows)} cards ({mode}) in {time.perf_counter() - t0:.1f}s", flush=True);
}
