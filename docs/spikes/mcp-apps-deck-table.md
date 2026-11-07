# Spike: show a deck as an HTML table in chat (MCP Apps)

Date: 2026-11-06. Branch: `spike/mcp-apps-deck-table`.

## Question

Can the UI the Jac app serves be embedded in an MCP tool response, so a deck
list shows as an HTML table in the chat?

## Answer

Yes, through the MCP Apps extension (`io.modelcontextprotocol/ui`, spec
2026-01-26). A tool carries `_meta.ui.resourceUri` pointing at a `ui://`
resource served as `text/html;profile=mcp-app`. The host renders that HTML in a
sandboxed iframe and posts the tool result into it over JSON-RPC
(`ui/initialize`, then `ui/notifications/tool-result`).

The pinned `mcp==2.3.0` already ships this as `mcp.server.apps.Apps`, so no new
dependency is needed.

## What the prototype does

- `deck_show(deck_id)` is a new tool bound to `ui://knowledge-pool/deck-table.html`.
  It runs the same `GetDeck` walker as `deck_get` and returns the deck as
  `structuredContent` (for the view) plus a Markdown table as text (for clients
  that do not render apps, and for the model).
- `ui/deck_table.html` is a self-contained page (no SDK, no network) that does
  the handshake, renders main deck and sideboard tables with totals and
  legality, follows the host's theme variables, and reports its height.
- `scripts/mcp_smoke.py` now checks the tool metadata, the resource MIME type
  and both halves of the `deck_show` result.

## Why not embed the Jac web UI itself

The Jac UI is a jac-client React app that calls `:pub` walkers over HTTP on
localhost:8000. Inside a host iframe that breaks down:

- The iframe's CSP blocks network by default. Opening `connectDomains` to
  `http://localhost:8000` only helps on the same machine, and needs CORS on the
  Jac server. claude.ai (web) cannot reach localhost at all.
- The app would have to be bundled into one HTML document (or its assets
  allowed via `resourceDomains`), which jac-client does not do today.

So the view renders from the tool result instead. The data is the same
`DeckView` the web UI uses, so the two stay in step.

## Client support (as of Nov 2026, from public docs; not tested here)

| Client | Renders MCP Apps |
|---|---|
| Claude Desktop, claude.ai, Claude mobile | Yes. claude.ai needs a remote server, so this local stdio server only fits Desktop. |
| Claude Code (CLI) | No. It gets the Markdown table. |
| VS Code Copilot | Behind `chat.mcp.apps.enabled` (off by default). |
| Cursor | Yes. |
| ChatGPT | Web, Business/Enterprise, remote servers only. |

Untested: rendering in a real Claude Desktop. The view was checked in headless
Chromium against a minimal fake host.

## Recommended next steps

1. Try it in Claude Desktop (`claude_desktop_config.json` pointing at
   `uv run --directory <repo> jac run mcp_server.jac`) and ask Claude to show a deck.
2. If it holds up, decide whether `deck_get`/`deck_edit` should also be bound
   to the view, or keep one explicit `deck_show` so the chat is not filled with
   tables during multi-step edits.
3. Later, interactive edits: the view can call `deck_edit` back through the
   host (`tools/call`), which gives count steppers in chat without touching
   localhost.
4. Hosted deployment (Railway plan): claude.ai requires `_meta.ui.domain` set
   from the SHA-256 of the server URL; add it when the server goes remote.
