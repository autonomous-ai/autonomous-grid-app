import 'dart:io';

import '../../../core/grid_paths.dart';

/// The one web-search skill both agents get, so "search the news" works the same
/// whichever is answering.
///
/// Codex on a grid has **no** web search of its own — its `web_search` is an
/// OpenAI-Responses server-side tool the grid relay doesn't serve — so a skill is
/// the only way to give it one. Hermes has a native `web_search` too (see
/// [ensureHermesWebSearch]); it gets the same skill so the two behave alike and
/// as a home for the future page-reading upgrade.
///
/// The search runs through `uv run --with ddgs`, so the DuckDuckGo backend is
/// provisioned on demand and cached — no API key, no account, and nothing for
/// the app to install up front. `uv` is the pinned one the grid CLI drops in
/// `~/.grid/bin`, which both agents can already reach.
const String kGridWebSkillName = 'grid-web';

/// The absolute `uv` the skill drives — the grid CLI's pinned copy, the same one
/// the ACP repair uses, so the skill never depends on a `uv` being on PATH.
String gridWebUvPath() => '${GridPaths.binDir.path}/uv';

/// Write (or refresh) the `grid-web` skill into [skillDir] — a `SKILL.md` the
/// agent reads to know when and how to search, plus the script it runs. Wipes the
/// folder first so a stale copy can't linger beside the current one. Idempotent.
Future<void> writeGridWebSkill(Directory skillDir, {String? uvPath}) async {
  if (await skillDir.exists()) await skillDir.delete(recursive: true);
  final scripts = Directory('${skillDir.path}/scripts');
  await scripts.create(recursive: true);
  final scriptPath = '${scripts.path}/search.py';
  await File('${skillDir.path}/SKILL.md').writeAsString(
    gridWebSkillMd(uvPath: uvPath ?? gridWebUvPath(), scriptPath: scriptPath),
  );
  await File(scriptPath).writeAsString(kGridWebSearchScript);
}

/// The skill card both agents read. Only the `name`/`description` frontmatter
/// decides *when* it triggers, so those carry the intent; the body is loaded only
/// once it fires and spells out the one command to run.
String gridWebSkillMd({required String uvPath, required String scriptPath}) =>
    '''
---
name: $kGridWebSkillName
description: Search the web for current, live, or online information — news, recent events, prices, today's facts, anything past your training. Use whenever the user asks about what's happening now, the latest, or to look something up online.
tags: [web-search, news, grid]
triggers:
  - user asks for news / the latest / current events / today / recent
  - user asks to look up, search, or find something online
  - "tin tức", "tìm trên mạng", "search the web", "look it up", "what's the latest"
---

# Search the web

You can search the live web. Run the bundled script — it needs no key and no
setup (the search backend is provisioned on first run and then cached):

```
"$uvPath" run --with ddgs python3 "$scriptPath" "<query>" [--max N]
```

It prints each result as three lines — title, URL, then a snippet — separated by
a blank line. Read them, then answer in your own words and **cite the URLs** you
used. `--max` caps the number of results (default 5).

## If it fails
- Exit code 2 = the search backend couldn't be provisioned (no `uv`/network).
  Tell the user web search isn't available right now.
- Empty output = no results; try a shorter or reworded query once, then say so.
- DuckDuckGo can rate-limit a burst of searches — if it errors, wait and retry
  once rather than hammering it.
''';

/// The search itself: a tiny, credential-free DuckDuckGo query via the `ddgs`
/// package. Kept dependency-light on purpose — it is run under `uv run --with
/// ddgs`, which supplies `ddgs` without touching either agent's environment.
const String kGridWebSearchScript = r'''#!/usr/bin/env python3
"""Search the web via DuckDuckGo (the `ddgs` package).

Meant to be run as:
    <uv> run --with ddgs python3 search.py "<query>" [--max N]
so `ddgs` is provisioned on demand. Prints one result per block:
    title
    url
    snippet
(blank line between). Exit 2 if ddgs is unavailable, 1 on a search error.
"""

import argparse
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description="Search the web (DuckDuckGo).")
    parser.add_argument("query", help="what to search for")
    parser.add_argument("--max", type=int, default=5, dest="max_results")
    args = parser.parse_args()

    try:
        from ddgs import DDGS
    except ImportError:
        print("ddgs is not available", file=sys.stderr)
        return 2

    try:
        rows = list(DDGS().text(args.query, max_results=max(1, args.max_results)))
    except Exception as exc:  # noqa: BLE001 - any failure is "couldn't search"
        print(f"search failed: {exc}", file=sys.stderr)
        return 1

    if not rows:
        print("No results.")
        return 0

    for row in rows:
        title = (row.get("title") or "").strip()
        url = (row.get("href") or row.get("url") or "").strip()
        snippet = (row.get("body") or row.get("snippet") or "").strip()
        print(f"{title}\n{url}\n{snippet}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
''';
