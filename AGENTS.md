# Working in this Jac project

This is a [Jac](https://www.jaseci.org/) project. Jac's syntax has evolved and
is easily confused with Python or JSX. Before writing or editing `.jac` files,
run `jac guide jac-core-cheatsheet` and `jac guide jac-types`; `jac guide` lists
the rest (`--search <keyword>` finds one by topic).

## Commands

- `jac` is the binary at the version `jac.toml` pins (`[project] jac-version`); `scripts/install_jac.sh` installs it and `jac install --dev` the packages. There is no `uv`.
- `jac x` lists this repo's commands. Run them as `jac x <name>`; it cannot pass arguments.
- Validate with `jac x check` (type-check, walker tests, pytest, then `jac db prune -y`: what CI runs). `jac check <file>` links diagnostics to guides; follow the `-> run 'jac guide ...'` hints. Run one test file with `jac x pytest tests/<file>` (`jac x pytest` takes arguments; scripts do not).
- Run the app with `jac x up|status|down`: the web app and the MCP server as two processes, one pair per worktree, web and MCP URLs printed. Leave `pkill -f` alone; `down` stops only this worktree's pair. QA the running app with `jac browse` (see the `run-knowledge-pool` skill).
- The deck graph is in Postgres: locally, the server Jac starts itself, with one database per worktree path. `jac db status` names this worktree's. Tests that start Jac processes take the `jac_db_url` fixture, never this worktree's database.
- Strict permissions are on in every app process (`runner.jac` sets them): a write Jac refuses fails the call.
- The catalogue is built from `~/.cache/knowledge-pool/` by `jac x up` or `jac x catalogue`; do not hunt for `AtomicCards.json.xz`.
- Grow `tests/fixtures/atomic_small.json` with `scripts/fixture_cards.py`.
- Review against `CODING_STANDARDS.md`.

## Orchestrated work

Dispatch workers into Orca worktrees, or run them on the feature branch one at a time. Don't start subagents with Claude Code's `isolation: "worktree"` option: its worktrees under `.claude/worktrees/` had commands refused as "too complex to verify" and failed to start without a `WorktreeCreate` hook (#83).

## GitHub

- Read issues with `gh issue view N --json title,body,comments`.
- Update PR bodies with `gh api -X PATCH repos/DaveParr/knowledge-pool/pulls/N -F body=@file`.
- Move board cards with `scripts/board.sh <issue> <status>`.

## Jac gotcha

`jac run` prints every walker `report` to stdout, and `jac run <file>` serves the app unless given `--no-serve`. Wrap walker calls in `redirect_stdout`, as `seed.jac`'s `walk` helper does.

## Agent skills

### Issue tracker

GitHub issues in `DaveParr/knowledge-pool`, with work prepared on the Knowledge Pool project board. See `docs/agents/issue-tracker.md`.

### Triage labels

The default five: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
