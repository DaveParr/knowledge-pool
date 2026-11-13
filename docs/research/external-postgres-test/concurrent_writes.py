import json, sys, urllib.request, anyio, threading, collections
from mcp.client.session import ClientSession
from mcp.client.streamable_http import streamable_http_client
WEB, MCP, DID = sys.argv[1], sys.argv[2], sys.argv[3]
MOUNTAIN="a3fb7228-e76b-4e96-a40e-20b5fed75685"
codes=collections.Counter()
def web(i):
    req = urllib.request.Request(f"http://127.0.0.1:{WEB}/walker/SetCardCount", data=json.dumps({"deck_id": DID, "oracle_id": MOUNTAIN, "zone": "main", "count": 10+i}).encode(), headers={"Content-Type": "application/json"})
    try:
        j=json.load(urllib.request.urlopen(req, timeout=60)); codes["web ok" if j["ok"] else "web notok"]+=1
    except Exception as e: codes["web "+str(e)[:40]]+=1
async def main():
    ts=[threading.Thread(target=web,args=(i,)) for i in range(25)]
    async with streamable_http_client(f"http://127.0.0.1:{MCP}/mcp") as (r, w):
        async with ClientSession(r, w) as s:
            await s.initialize()
            for t in ts: t.start()
            for i in range(10):
                res = await s.call_tool("deck_edit", {"deck_id": DID, "changes": [{"oracle_id": MOUNTAIN, "count": 40+i, "zone": "main", "reason": f"mcp {i}"}]})
                codes["mcp err" if res.is_error else "mcp ok"]+=1
            for t in ts: t.join()
            g = await s.call_tool("deck_get", {"deck_id": DID}); sc=g.structured_content or {}; sc=sc.get("result",sc); print("get is_error", g.is_error)
            print("final via mcp:", [(l["name"], l["count"]) for l in sc.get("lines", sc.get("cards", []))], "history", len(sc.get("history", [])))
    print(dict(codes))
anyio.run(main)
