# Grid app — read `docs/conventions.md`

**The conventions for this repo live in [`docs/conventions.md`](docs/conventions.md).
Read it before you touch anything.** Architecture, Riverpod rules, Dart style, copy
rules, testing policy, definition of done.

This file used to be a full copy of them. The copy drifted: it went on telling agents to
write widget tests and to auto-run review agents long after both rules were reversed — so
anyone who read this file instead of that one worked to rules the project had dropped.
One source now; this file carries only what is genuinely different for a non-Claude agent.

## What you need before the hop

- **Reply to the user in Vietnamese.**
- **Flutter / Dart**, not React or Node — no pnpm, no TypeScript, no CSS modules. The SDK
  is not on the default `PATH` here:
  `export PATH="$HOME/WorkPlace/Flutter/flutter/bin:$PATH"`.
- **Gate before "done":** `flutter analyze lib test` → 0 issues, plus the relevant
  `flutter test test/<area>`. Both bars are clear on `main` (measured 2026-08-06), so a
  failure you see is yours to fix rather than a known one to report around.
- **No new widget/UI tests.** Logic only (§8).
- **Never commit straight to `main`:** branch → commit → merge → push.

## Tool-specific overrides

- **Codex** — end commit messages with
  `Co-Authored-By: Codex Opus 4.8 <noreply@anthropic.com>` (Claude signs with its own
  name; everything else about commits is §10).
- The `code-tester` / `ui-ux-reviewer` subagents named in `CLAUDE.md` are Claude Code
  subagents. On another tool, do that work yourself — and, as there, **only when the user
  asks for it**.

<!-- gitnexus:start -->
## GitNexus — the codebase as a queryable graph

This project is indexed by GitNexus as **autonomous-grid-app** (18442 symbols, 35020
relationships, 214 execution flows). Use it where a graph beats grep — it knows callers
across files, `implements` edges, and execution flows.

> Rewritten by hand from the block `gitnexus setup` generates: the original made impact
> analysis mandatory before *every* edit, which is not a trade worth making on a one-line
> copy fix. **Re-running `gitnexus setup` overwrites everything between these markers** —
> restore this version from git if that happens.

- **Before editing a symbol whose callers don't fit in one file**, run
  `impact({target: "Symbol", direction: "upstream"})` and report the blast radius. Say so
  out loud when it comes back HIGH or CRITICAL — don't quietly proceed.
- **Exploring unfamiliar code:** `query({search_query: "concept"})` returns execution
  flows grouped by process, `context({name: "Symbol"})` gives callers + callees + flows.
- **Renaming across files:** use `rename`, which understands the call graph. Never
  find-and-replace a symbol.
- **Before committing a wide change:** `detect_changes({scope: "compare", base_ref:
  "main"})` maps the diff onto symbols and flows, so a surprise shows up before review
  does. Not needed for a diff you can read in full.

Index stale after a pull? `node .gitnexus/run.cjs analyze`. No `.gitnexus/` at all (fresh
clone — the index is gitignored)? `npx gitnexus analyze`.

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/autonomous-grid-app/context` | Codebase overview, index freshness |
| `gitnexus://repo/autonomous-grid-app/clusters` | All functional areas |
| `gitnexus://repo/autonomous-grid-app/processes` | All execution flows |
| `gitnexus://repo/autonomous-grid-app/process/{name}` | Step-by-step execution trace |
<!-- gitnexus:end -->
