# What Jac provides for users, sign-in and per-user graphs

Research for issue #90, part of map #87. Written 2026-11-10 against the versions pinned in `pyproject.toml`: `jaclang==0.16.7` and `jac-client==0.3.25`. `jac-scale` is not installed.

Paths that start with `jaclang/` are inside the installed package, at `.venv/lib/python3.14/site-packages/jaclang/`. Paths that start with `jac_scale/` are inside the `jac-scale` 0.2.31 wheel from PyPI, which was downloaded and read but not installed or run.

## Short answer

Jac as pinned gives each user a private graph root and a username-and-password sign-in. It has no Google sign-in, no invite list and no way to switch off public registration. Google sign-in exists only in the separate `jac-scale` plugin, and that plugin creates an account for any Google user who completes sign-in.

A Jac user is one row in a SQLite table: a username, a password hash, a permanent token and a root id. Running a walker as a user from outside the web app needs only the username: look up the root id and set it on the execution context, as `shared_graph.jac` already does for the guest user. No password or token is involved. So a sign-in step placed in front of Jac can map a verified Google email to a Jac user without using Jac's own sign-in at all.

Jac's cross-user access rules did not hold up in tests on the pinned version. A signed-in user could read another user's deck through three ordinary routes without any grant, and by default could overwrite it. Setting `JAC_STRICT_PERMISSIONS=1` stopped the overwrite but not the reads. Whichever way decks are owned, the app's own walkers have to check that the caller may see or change the deck; Jac's permission layer cannot be the only gate.

## Terms

- **Root**: the top node of one user's graph. Every node a user creates is owned by that user's root.
- **Guest root**: the root of the built-in user `__guest__`. Requests with no token run on it. Jac code reaches it as `root.shared`.
- **System root**: a fixed root that has write access to everything. Code that runs outside any request, such as `jac run`, uses it.
- **Walker**: a Jac object that runs on a node of the graph. The server exposes each walker at `POST /walker/<Name>`.
- **`:pub`**: an access tag on a walker or function that makes its endpoint callable without a token.
- **Grant**: a record on a node saying another root, or every root, may read, connect to or write it.
- **jac-scale**: a separate Jac plugin that replaces the built-in server with a FastAPI server and adds JWT sessions, single sign-on, roles and an admin portal.

## Facts

### 1. The pinned project runs Jac's built-in server, not jac-scale

- `pyproject.toml` pins `jac-client==0.3.25`, `jaclang==0.16.7` and `mcp==2.3.0`. `uv run jac --version` lists one plugin, `jac-client`.
- `mcp_server.jac` lines 565-572 start the web app with `Jac.get_api_server_class()`. With no jac-scale installed this is `JacAPIServer` from `jaclang/runtimelib/server.jac`, built on Python's `http.server`.
- The guides printed by `jac guide jac-sv-auth`, `jac-sv-multi-user` and `jac-cl-auth` ship inside jaclang 0.16.7 but describe jac-scale in several places: JWT, email identities, roles, the `/admin` portal, `/user/me`, token refresh and `/sso/...` routes. None of those exist in the built-in server. Treat those guides as a description of jaclang plus jac-scale.

### 2. What a user is in the built-in server

- Users live in a SQLite table `users(username, password_hash, token, root_id)` in `<JAC_DATA_PATH or app dir>/.jac/data/main.db` (`jaclang/runtimelib/impl/server.impl.jac` lines 12-52). This is the same folder as the saved graph.
- `UserManager.create_user(username, password)` makes a new `Root` node, saves it, and stores the row with a random 32-byte token (lines 55-83).
- The password hash is unsalted SHA-256 (line 75). The token is created once and never changes or expires; `/user/login` returns the same token every time (lines 86-103, confirmed by test). There is no sign-out on the server and no way to revoke a token short of editing the database.
- The only identity type is `username` and the only credential type is `password` (`jaclang/runtimelib/auth_models.jac` lines 3-12).
- Endpoints: `POST /user/register`, `POST /user/login`, `GET /user/info`, `PUT /user/username`, `PUT /user/password` (server.impl.jac lines 2241-2256, 2291-2335, 2450-2469).
- `POST /user/register` is always on and needs no token. Anyone who can reach the server can create a user. There is no setting to disable it and no invite or allow list.
- There are no roles and no admin user in the built-in server.
- Every response carries `Access-Control-Allow-Origin: *` (lines 1511-1515).
- A request is authenticated only by an `Authorization: Bearer <token>` header (lines 1854-1866). Cookies are not read. The browser client keeps the token in `localStorage` under `jac_token` (`jaclang/runtimelib/impl/client_runtime.impl.jac` lines 433-463, 501-504).

### 3. `:pub` walkers compared with authenticated ones

Source: server.impl.jac lines 1420-1434 and 2336-2386; `jac guide jac-sv-auth`; confirmed by test.

- A plain `walker` or `def`, or one tagged `:priv`, needs a valid token. Without one the server answers 401. It runs on the caller's own root.
- A `walker:pub` or `def:pub` needs no token. With no token it runs on the guest root. With a valid token it runs on that user's root. So `root` inside a `:pub` walker is not one fixed graph.
- Any endpoint whose access tag the server cannot work out defaults to needing a token.
- In this app every deck walker is `:pub` (`decks.sv.jac` line 4 and following), which is why all decks sit on the guest root today. Making decks per-user means dropping `:pub` from them, or keeping `:pub` and always sending a token.
- The web page itself is served to anyone. `main.jac` line 23 declares `def:pub app`, and the server renders pages for the guest user when no token is sent (server.impl.jac lines 1981-1999). Jac has no built-in way to hide the page behind sign-in; the client can redirect with `AuthGuard` (`jac guide jac-cl-auth`), which runs in the browser and is not an access control.

### 4. Running a walker as a given user from outside the web app

- `shared_graph.jac` lines 26-53 do this for the guest user: get the user manager, read the root id with `um.get_root_id(username)`, make an `ExecutionContext` forked from the process context, call `ctx.set_user_root(root_id)`, push it with `Jac.push_request_context`, spawn the walker on `ctx.get_root()`, commit, and reset.
- The same steps work for any username. Tested: after registering `alice`, a walker spawned this way with `um.get_root_id("alice")` reported Alice's root and Alice's decks.
- `um.create_user(username, password)` can be called in process to create a user and root on first sight, as `shared_graph.jac` does for the guest. The password is then unused if nothing ever signs in through `/user/login`.
- This is what the server itself does per request (`_begin_request_context`, server.impl.jac lines 276-287). It needs the username only. It is the route by which an MCP tool call, or any code that already knows who the caller is, can act as that user.
- A context whose user root was never set runs as the system root, which may write anything (`jaclang/runtimelib/impl/context.impl.jac` lines 44-56; `check_access_level` in `jaclang/jac0core/impl/runtime.impl.jac` lines 143-158).
- For the REST surface the built-in server has no hook that takes identity from a request header. `jac guide jac-sv-endpoints` and the jac-scale docs mention an `_authenticate` middleware walker, but no code for it was found in jaclang 0.16.7 or jac-scale 0.2.31 (see "Not confirmed"). A browser call reaches a user's root only if it carries that user's Jac token.

### 5. Letting one user read another user's nodes

The designed model, from `jac guide jac-sv-multi-user` and `jaclang/jac0core/impl/runtime.impl.jac` lines 69-176:

- Access levels are `NoPerm`, `ReadPerm`, `ConnectPerm` (may attach edges) and `WritePerm`.
- `grant(node, level)` opens one node to every user. `revoke(node)` undoes it.
- `Jac.allow_root(node, UUID(root_id), level)` opens one node to one user. `Jac.disallow_root(node, UUID(root_id))` undoes it. It needs `import from jaclang { JacRuntime as Jac }`.
- Grants are per node. A grant on a deck does not cover the nodes hanging off it. One exception, from the source (runtime.impl.jac lines 165-172): a grant placed on a user's root node applies to every node that root owns.
- A node type can compute its own level by overriding `__jac_access__` (`jaclang/jac0core/archetype.jac` line 169).
- `root.shared` is the guest root. Every user may read it and attach nodes to it. A node attached there stays owned by its author.
- `allroots()` returns every user's root.
- The owner's root id is needed for a per-user grant. It is in the login response and in `jid(root)`.
- A read that is not allowed is meant to be silent: the node is left out of the traversal. A write that is not allowed is meant to be dropped when the request commits, with a warning in the response.

Copying a shared deck fits this model: a walker running as the reader reads the granted deck and creates new nodes under the reader's own root.

### 6. What the tests showed: the access rules leak

Method: a scratch app with a `Deck` node and a few walkers, driven by `JacTestClient` from `jaclang/runtimelib/testing.jac`, which runs the built-in server's request handler in process without a socket. Two users, Alice and Bob, were registered. Alice created a deck. Nothing was granted. The scripts are in the appendix.

| Bob's action, with no grant | Result |
| --- | --- |
| `[alice_root -->]` (no type filter) | Empty. Access rule held. |
| A walker spawned on Alice's root that does `visit [-->]` | Visited nothing. Access rule held. |
| `[alice_root -->][?:Deck]` and `[alice_root --> [?:Deck]]` (type filter) | Returned Alice's deck. |
| `jobj(deck_id)` then read a field | Returned the deck's name. |
| `POST /walker/ReadDeck/<deck_id>` (spawn a walker directly on the node) | Ran on Alice's deck and reported its name. |
| `allroots()` with a typed filter | Listed every user's decks. |
| `POST /walker/Rename/<deck_id>` (write a field) | Response carried a "Permission denied" warning, yet Alice then saw the new name, and it was still there after the process was restarted. |
| The same write with `JAC_STRICT_PERMISSIONS=1` | The walker failed with the permission error; the name was unchanged, in process and after restart. |
| Anonymous `POST /walker/<PubWalker>/<alice_root_id>` | A `:pub` walker ran on Alice's root with no token and listed her decks. |

`Jac.check_access_level` returned `NO_ACCESS` for Bob on Alice's deck throughout, so the grants were right and the enforcement was missing. Likely causes, from the source:

- Typed traversals go through a query planner (`jaclang/runtimelib/impl/planner.impl.jac`, called from runtime.impl.jac lines 1285-1299) that contains no access check. The untyped path checks each node (runtime.impl.jac lines 235 and 243).
- `jobj` looks a node up by id with no access check (runtime.impl.jac lines 757-764). The guide says so too: "don't treat a jid as a secret capability".
- The server spawns a walker on any node id in the URL without a read check (server.impl.jac lines 590-597). The command-line path does check (`jaclang/cli/commands/impl/execution.impl.jac` line 445).
- All requests in one process share one in-memory graph, so a field Bob changes is seen by Alice at once. Write checks run only when changes are saved (`jaclang/runtimelib/impl/memory.impl.jac` lines 2156-2208). Strict mode raises the error earlier and the server then discards the request's changes (server.impl.jac lines 629-635).

What this means for this app:

- `DeckAction` in `decks.sv.jac` lines 340-357 finds a deck with `jobj(self.deck_id)`. With per-user roots and no other change, any signed-in user who knows or guesses a deck id could view and edit it. The walker would need its own check that the deck is the caller's or is shared with the caller.
- Node ids are random UUIDs, but they appear in URLs and responses, and the typed `allroots()` route lists other users' nodes without knowing any id.
- The `Card`, `Catalog` and `Format` nodes hang off `root` (`cards.sv.jac` line 116, `legality.sv.jac` line 57). With per-user roots each user would get a separate copy unless these move to `root.shared`.

### 7. What jac-scale would add

Read from the jac-scale 0.2.31 wheel and https://docs.jaseci.org/reference/plugins/jac-scale-http/. Not installed, not run.

- Google, Apple and GitHub sign-in through `fastapi-sso` (`jac_scale/sso/google.jac`). Configure `[plugins.scale.sso.google]` with `client_id` and `client_secret`, plus `host` and `client_auth_callback_url`. Routes: `GET /sso/google/login`, `/sso/google/register`, `/sso/google/callback`. Docs: https://docs.jaseci.org/reference/plugins/jac-scale-http/#sso-single-sign-on
- On callback, if a user with that email exists the Google identity is linked and a token returned. If not, a new user is created (`jac_scale/impl/user_manager.impl.jac` lines 350-445). The `login` and `register` routes end in the same callback. No allow list, invite list or switch to disable sign-up was found in the wheel, and `POST /user/register` with a password stays on. An invite-only group would need a check added outside jac-scale or a change to it.
- After sign-in the server redirects the browser to `client_auth_callback_url?token=<JWT>`, so the token travels in a URL (`jac_scale/impl/serve.auth.impl.jac` line 356). The client helper `jacSsoLogin("google")` in jaclang starts this flow (`client_runtime.impl.jac` lines 543-573).
- Sessions are JWTs signed with HS256, valid 7 days by default, with no revocation. The default signing secret is the public string `supersecretkey_for_testing_only!` and must be replaced (`jac_scale/impl/config_loader.impl.jac` lines 10-12; `jac guide jac-sv-auth`).
- Passwords are hashed with bcrypt. Roles `admin`, `system` and `user` exist, with an admin portal at `/admin` and a bootstrap admin created on first start.
- jac-scale's sign-in is not an OAuth authorization server. It has no dynamic client registration or token endpoint of the kind a claude.ai connector uses to sign a user in. Its API keys are documented for webhook endpoints only (https://docs.jaseci.org/reference/plugins/jac-scale-http/#api-key-management).
- Dependencies: a `uv pip compile` of `jaclang==0.16.7`, `jac-client==0.3.25`, `mcp==2.3.0` and `jac-scale` resolved, to jac-scale 0.2.31 with fastapi 0.121.3, starlette 0.50.0, uvicorn 0.38.0 and pyjwt 2.10.1. Today's lock has starlette 1.10.0, uvicorn 0.54.0 and pyjwt 2.15.1, so adding jac-scale moves those down. The jac-scale wheel declares no jaclang version requirement. jac-scale 0.2.30 was published one minute after jaclang 0.16.7 (PyPI upload times, 2026-06-19), and 0.2.31 six days later.
- jac-scale replaces the server class, so `mcp_server.jac`'s `start_web` and `shared_graph.jac`'s use of the built-in `UserManager` would both change. Its user store uses SQLAlchemy; storage choices belong to ticket #91.
- The traversal and `jobj` code paths in fact 6 are in jaclang itself, so jac-scale would not be expected to change them. This was not tested.

## Options the facts leave open

Sign-in:

1. **In front of Jac.** A proxy or the app's own HTTP layer verifies the Google identity and the invite list. The app maps the verified email to a Jac username and sets that user's root, as in fact 4. Jac's `/user/register` and `/user/login` must then be unreachable from outside, because they would let anyone create a user. The MCP surface fits this directly, since it already runs walkers in process. The browser surface needs a way to carry the identity to the walker, because the built-in REST server only accepts a Jac token: either the layer in front adds the user's `Authorization: Bearer` header, or the web UI's calls go through code that sets the root itself.
2. **By Jac, with jac-scale.** Google sign-in comes ready-made for the browser. It still needs an invite check, a replacement JWT secret, the dependency downgrades above, and rework of how this app starts its server. It does not cover the claude.ai connector's sign-in.
3. **By Jac's built-in server alone.** Only usernames and passwords, open registration, permanent tokens, unsalted hashes. This does not meet "sign in with Google" or "invite-only".

Deck ownership:

1. **Per-user roots.** Each user's decks hang off their own root. Sharing uses `allow_root` or `grant`; copying creates nodes under the reader's root. Shared catalogue nodes move to `root.shared`. App-level checks are still needed (fact 6), and `JAC_STRICT_PERMISSIONS=1` is needed to stop cross-user writes.
2. **One root, with an owner recorded on each deck.** All decks stay on one root and every walker filters by an owner field. Jac's user and grant machinery is unused; all isolation is app code.

In both options the app must check ownership itself. The difference is whether Jac's roots add a second layer and a place to hang grants.

## Not confirmed

- The leaks in fact 6 were reproduced with the in-process test client, which uses the same request handler as the real server. They were not reproduced against a running `jac start` over a socket, because the brief ruled out starting servers.
- Whether the leaks also occur under jac-scale, or in jaclang releases after 0.16.7. PyPI showed 0.16.7 as the latest jaclang on 2026-11-10.
- Whether the leaks are known upstream. The Jaseci issue tracker was not searched.
- Why the denied write survived a restart without strict mode. It was observed twice; the exact flush path was not traced.
- The `_authenticate` and `_before_request` middleware walkers named in `jac guide jac-sv-endpoints` and in the jac-scale docs (https://docs.jaseci.org/reference/plugins/jac-scale-http/#authentication-middleware). A search of both packages found no code that calls them.
- jac-scale's behaviour in practice: nothing in fact 7 was run. In particular the absence of a sign-up switch is from reading and searching the wheel, not from a running server.
- Whether a grant on a root node really covers every node the root owns. This is read from the source and was not tested.

## Appendix: the test

Run from the repo folder with `JAC_DATA_PATH= uv run python <script>`, with the app file and script outside the repo.

```jac
import from jaclang { JacRuntime as Jac }
import from uuid { UUID }

node Deck { has name: str; }

walker:pub PubList {
    can go with Root entry {
        report {"root": jid(here), "decks": [d.name for d in [here -->][?:Deck]]};
    }
}
walker Create {
    has name: str;
    can go with Root entry {
        d = (here ++> Deck(name=self.name))[0];
        report {"id": jid(d), "root": jid(here)};
    }
}
walker ListMine {
    can go with Root entry {
        report {"root": jid(here), "decks": [d.name for d in [here -->][?:Deck]]};
    }
}
walker ReadDeck { can go with Deck entry { report here.name; } }
walker Rename {
    has name: str;
    can go with Deck entry { here.name = self.name; report here.name; }
}
walker Probe {
    has root_id: str;
    has deck_id: str;
    can go with Root entry {
        r = jobj(self.root_id);
        d = jobj(self.deck_id);
        report {
            "level_on_deck": str(Jac.check_access_level(d.__jac__)),
            "typed_postfilter": [x.name for x in [r -->][?:Deck]],
            "typed_inline": [x.name for x in [r --> [?:Deck]]],
            "untyped": [type(x).__name__ for x in [r -->]]
        };
    }
}
```

```python
from jaclang.runtimelib.testing import JacTestClient
c = JacTestClient.from_file("app.jac", base_path=data_dir)
a = c.register_user("alice", "pw-a").json()["data"]   # username, token, root_id
b = c.register_user("bob", "pw-b").json()["data"]
c.set_auth_token(a["token"])
deck = c.post("/walker/Create", json={"name": "A1"}).json()["data"]["reports"][0]["id"]
c.set_auth_token(b["token"])
c.post("/walker/Probe", json={"root_id": a["root_id"], "deck_id": deck})
# -> level_on_deck NO_ACCESS, typed_postfilter ["A1"], typed_inline ["A1"], untyped []
c.post(f"/walker/ReadDeck/{deck}", json={})                    # -> ["A1"]
c.post(f"/walker/Rename/{deck}", json={"name": "HACKED"})      # -> 200 with a warning
c.close()
# New process, same data_dir, as Alice: ListMine -> ["HACKED"].
# With JAC_STRICT_PERMISSIONS=1 the Rename returns an error and ListMine -> ["A1"].
c.clear_auth()
c.post(f"/walker/PubList/{a['root_id']}", json={})             # -> Alice's decks, no token
```
