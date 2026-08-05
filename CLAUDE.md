# Grid app — Claude Code

The conventions for this repo live in **[`docs/conventions.md`](docs/conventions.md)**,
imported below. Read it before you touch anything. It is tool-neutral — architecture,
Riverpod rules, Dart style, copy rules, testing policy, definition of done — and it is
the only copy. Everything under this line is what is *different* for Claude Code.

@docs/conventions.md

## Claude Code specifics

- **Reply to the user in Vietnamese.**
- **These rules override the global `~/.claude/CLAUDE.md`.** That one is React/TS/Node —
  no pnpm, no TypeScript, no CSS modules. This is Flutter/Dart.
- **Subagents are on-demand, never automatic.** Run `code-tester` (analyze + tests) or
  `ui-ux-reviewer` (judges a UI diff as a first-time user) **only when the user asks**.
- Commit messages end with a `Co-Authored-By:` trailer naming **the model that actually
  wrote them** — `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`, not a version
  copied from this file (§10).

## GitNexus

The repo is indexed into a knowledge graph, so "what breaks if I change this" is a
query, not a guess. The `gitnexus-*` skills carry the full reference; the two worth
reaching for by hand:

- `impact({target: "Symbol", direction: "upstream"})` before editing a symbol whose
  callers you can't see in one file — report the blast radius rather than assuming it.
- `query({search_query: "concept"})` to find an execution flow when you'd otherwise
  grep blind.

Stale after a pull? `node .gitnexus/run.cjs analyze`. The index itself is gitignored,
so a fresh clone has none until someone runs it.
