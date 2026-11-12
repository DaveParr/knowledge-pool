"""Check the verifier locally with a made-up key pair standing in for AuthKit.

Run with the repo's Python:  .venv/bin/python spikes/workos-live-test/local_test.py
"""
import json, os, subprocess, sys, threading, time, urllib.error, urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer
import jwt
from cryptography.hazmat.primitives.asymmetric import rsa

key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
other = rsa.generate_private_key(public_exponent=65537, key_size=2048)
jwk = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(key.public_key())) | {"kid": "k1", "use": "sig", "alg": "RS256"}

class Keys(BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"keys": [jwk]}).encode()
        self.send_response(200); self.send_header("content-type", "application/json"); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass

threading.Thread(target=HTTPServer(("127.0.0.1", 8791), Keys).serve_forever, daemon=True).start()
ISS, PUB = "https://fake.authkit.app", "http://127.0.0.1:8790"
env = os.environ | {"AUTHKIT_DOMAIN": ISS, "PUBLIC_URL": PUB, "PORT": "8790", "JWKS_URL": "http://127.0.0.1:8791/"}
proc = subprocess.Popen([sys.executable, os.path.join(os.path.dirname(os.path.abspath(__file__)), "server.py")], env=env)

def http(url, headers=None, data=None):
    req = urllib.request.Request(url, headers=headers or {}, data=data)
    try:
        with urllib.request.urlopen(req, timeout=10) as f: return f.status, f.headers, f.read().decode()
    except urllib.error.HTTPError as e: return e.code, e.headers, e.read().decode()

def token(signer=key, **over):
    claims = {"iss": ISS, "aud": PUB + "/mcp", "sub": "user_123", "client_id": "https://claude.ai/x", "exp": int(time.time()) + 300} | over
    return jwt.encode(claims, signer, algorithm="RS256", headers={"kid": "k1"})

def call(tok=None):
    headers = {"accept": "application/json, text/event-stream", "content-type": "application/json", "MCP-Protocol-Version": "2025-06-18"}
    if tok: headers["authorization"] = "Bearer " + tok
    body = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "whoami", "arguments": {}}}
    return http(PUB + "/mcp", headers, json.dumps(body).encode())

failed = False
try:
    for _ in range(50):
        try: http(PUB + "/.well-known/oauth-protected-resource/mcp"); break
        except OSError: time.sleep(0.2)
    status, _, text = http(PUB + "/.well-known/oauth-protected-resource/mcp"); print("metadata", status, text)
    status, headers, _ = call(); print("no token", status, headers.get("www-authenticate"))
    for name, tok, want in [("good", token(), 200), ("wrong audience", token(aud="https://elsewhere/mcp"), 401),
                            ("wrong issuer", token(iss="https://evil"), 401), ("expired", token(exp=int(time.time()) - 5), 401),
                            ("wrong key", token(signer=other), 401)]:
        status, _, text = call(tok)
        failed |= status != want
        print("PASS" if status == want else "FAIL", name, status, text[:120].replace("\n", " "))
finally:
    proc.terminate()
sys.exit(1 if failed else 0)
