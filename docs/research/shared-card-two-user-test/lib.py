import json, sys, urllib.request, urllib.error
B = "http://127.0.0.1:" + open(sys.argv[1]).read().strip()
def call(path, body=None, token=None, method="POST"):
    h = {"Content-Type": "application/json"}
    if token: h["Authorization"] = "Bearer " + token
    data = json.dumps(body if body is not None else {}).encode() if method == "POST" else None
    req = urllib.request.Request(B + path, data=data, headers=h, method=method)
    try:
        with urllib.request.urlopen(req) as r: code, txt = r.status, r.read().decode()
    except urllib.error.HTTPError as e: code, txt = e.code, e.read().decode()
    try: js = json.loads(txt)
    except Exception: js = txt
    return code, js
def user(name):
    pw = "plum-Harbour-9941-" + name[::-1]
    c, j = call("/user/register", {"identities": [{"type": "username", "value": name}], "credential": {"type": "password", "password": pw}})
    if c != 200 and c != 201:
        c, j = call("/user/login", {"identity": {"type": "username", "value": name}, "credential": {"type": "password", "password": pw}})
    return j["data"]["token"], j["data"]["root_id"]
def show(label, res):
    c, j = res
    if isinstance(j, dict) and "data" in j:
        d = j["data"]
        if isinstance(d, dict) and "result" in d: d = d["result"] if d.get("reports") in (None, []) else {"result": d["result"], "reports": d["reports"]}
        j = d
    print(f"## {label}\n[{c}] {json.dumps(j, indent=1, default=str)}\n")
    return j
