# Working in this Jac project

This is a [Jac](https://www.jaseci.org/) project. Jac's syntax has evolved and
is easily confused with Python or JSX. Before writing or editing `.jac` files,
run `jac guide jac-core-cheatsheet` and `jac guide jac-types`; `jac guide` lists
the rest (`--search <keyword>` finds one by topic).

## Commands

- `uv run jac script --list` lists this repo's commands. Run them as `uv run jac script <name>`.
- Validate with `jac script check` (type-check, walker tests, pytest: what CI runs). `jac check <file>` links diagnostics to guides; follow the `-> run 'jac guide ...'` hints.
- Run the app with `jac script up|status|down`: one server per worktree, web and MCP URLs printed. Leave `jac start` and `pkill -f` alone; `down` stops only this worktree's server. QA the running app with `jac browse` (see the `run-knowledge-pool` skill).
- The catalogue is built from `~/.cache/knowledge-pool/` by `jac script up` or `jac script catalogue`; do not hunt for `AtomicCards.json.xz`.
- Grow `tests/fixtures/atomic_small.json` with `scripts/fixture_cards.py`.
- Review against `CODING_STANDARDS.md`.

## Orchestrated work

Dispatch workers into Orca worktrees, or run them on the feature branch one at a time. Don't start subagents with Claude Code's `isolation: "worktree"` option: its worktrees under `.claude/worktrees/` had commands refused as "too complex to verify" and failed to start without a `WorktreeCreate` hook (#83).

## GitHub

- Read issues with `gh issue view N --json title,body,comments`.
- Update PR bodies with `gh api -X PATCH repos/DaveParr/knowledge-pool/pulls/N -F body=@file`.
- Move board cards with `scripts/board.sh <issue> <status>`.

## Jac gotcha

`jac run` prints every walker `report` to stdout. Wrap walker calls in `redirect_stdout`, as `seed.jac`'s `walk` helper does.
