---
name: run-knowledge-pool
description: Run, start or test the knowledge-pool app in this repo (web UI and MCP server) to see a change working.
---

1. `jac x up` builds the catalogue if needed, starts the web app and the MCP server (two processes, one database), then prints `web:`, `mcp:` and `log:` lines. If `jac` is missing or the wrong version, run `scripts/install_jac.sh` and `jac install --dev` first.
2. Open the `web:` URL: `jac browse open <web url>`, then `snapshot`, `click @e5`, `fill`, `screenshot`. The page needs a second or two to render; snapshot again if it is empty.
3. To use the MCP tools, run the printed `claude mcp add --transport http ...` line.
4. `jac x down` when finished.

`jac x status` reprints the URLs. The manual checks are in `docs/qa-mvp.md`; the automated browser test is `jac x test-ui`.
