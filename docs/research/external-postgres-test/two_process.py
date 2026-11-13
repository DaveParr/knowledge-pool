import json, sys, urllib.request, anyio
from mcp.client.session import ClientSession
from mcp.client.streamable_http import streamable_http_client
WEB, MCP = sys.argv[1], sys.argv[2]
def web(path, body=None):
    req = urllib.request.Request(f"http://127.0.0.1:{WEB}{path}", data=json.dumps(body or {}).encode(), headers={"Content-Type": "application/json"})
    return json.load(urllib.request.urlopen(req, timeout=30))
def val(res):
    if getattr(res, "structured_content", None): 
        sc = res.structured_content; return sc.get("result", sc) if isinstance(sc, dict) else sc
    return json.loads(res.content[0].text) if res.content else None
async def main():
    async with streamable_http_client(f"http://127.0.0.1:{MCP}/mcp") as (r, w):
        async with ClientSession(r, w) as s:
            await s.initialize()
            call = lambda n, a={}: s.call_tool(n, a)
            raw = await call("deck_list"); dl = val(raw); print("mcp deck_list:", [d["name"] for d in dl])
            names = val(await call("resolve_names", {"names": ["Lightning Bolt", "Mountain"]})); print("resolve:", json.dumps(names)[:200])
            if "--create" in sys.argv:
                ids = [x["oracle_id"] for x in names["exact"]]
                d = val(await call("deck_create", {"name": "mcp deck", "format": "modern", "cards": [{"oracle_id": ids[0], "count": 4, "zone": "main", "reason": "burn"}]}))
                print("mcp deck_create:", json.dumps(d)[:300])
                did = d["id"]
                wl = web("/walker/ListDecks")["data"]["reports"][0]; print("web ListDecks:", [x["name"] for x in wl])
                r = web("/walker/AddCard", {"deck_id": did, "oracle_id": ids[1], "count": 20, "zone": "main"}); print("web AddCard ok:", r["ok"], json.dumps(r["data"]["reports"])[:150])
                g = val(await call("deck_get", {"deck_id": did})); print("mcp deck_get lines:", [(l["name"], l["count"]) for l in g.get("lines", g.get("cards", []))] or json.dumps(g)[:300])
                e = val(await call("deck_edit", {"deck_id": did, "changes": [{"oracle_id": ids[1], "count": 18, "zone": "main", "reason": "trim lands"}]})); 
                wg = web("/walker/GetDeck", {"deck_id": did}); print("web GetDeck after mcp edit:", json.dumps(wg["data"]["reports"])[:600])
            else:
                for d in dl:
                    g = val(await call("deck_get", {"deck_id": d["id"]})); print(d["name"], json.dumps(g)[:300])
anyio.run(main)
