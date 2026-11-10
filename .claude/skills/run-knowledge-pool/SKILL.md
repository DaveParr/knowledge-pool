---
name: run-knowledge-pool
description: Run, start or test the knowledge-pool app in this repo (web UI and MCP server) to see a change working.
---

1. `uv run jac script up` builds the catalogue if needed, then prints `web:`, `mcp:` and `log:` lines.
2. Open the `web:` URL: `uv run jac browse open <web url>`, then `snapshot`, `click @e5`, `fill`, `screenshot`. The page needs a second or two to render; snapshot again if it is empty.
3. To use the MCP tools, run the printed `claude mcp add --transport http ...` line.
4. `uv run jac script down` when finished.

`uv run jac script status` reprints the URLs. The manual checks are in `docs/qa-mvp.md`; the automated browser test is `uv run jac script test-ui`.
