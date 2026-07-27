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
/// agent reads to know when and how to use it, plus the two scripts it runs
/// (search, and read one page). Wipes the folder first so a stale copy can't
/// linger beside the current one. Idempotent.
Future<void> writeGridWebSkill(Directory skillDir, {String? uvPath}) async {
  if (await skillDir.exists()) await skillDir.delete(recursive: true);
  final scripts = Directory('${skillDir.path}/scripts');
  await scripts.create(recursive: true);
  final searchScriptPath = '${scripts.path}/search.py';
  final readScriptPath = '${scripts.path}/read.py';
  await File('${skillDir.path}/SKILL.md').writeAsString(
    gridWebSkillMd(
      uvPath: uvPath ?? gridWebUvPath(),
      searchScriptPath: searchScriptPath,
      readScriptPath: readScriptPath,
    ),
  );
  await File(searchScriptPath).writeAsString(kGridWebSearchScript);
  await File(readScriptPath).writeAsString(kGridWebReadScript);
}

/// The skill card both agents read. Only the `name`/`description` frontmatter
/// decides *when* it triggers, so those carry the intent; the body is loaded only
/// once it fires and spells out the two commands — search, and read one page.
String gridWebSkillMd({
  required String uvPath,
  required String searchScriptPath,
  required String readScriptPath,
}) =>
    '''
---
name: $kGridWebSkillName
description: Search the web and read pages for current, live, or online information — news, recent events, prices, today's facts, a specific article or post, anything past your training. Use whenever the user asks about what's happening now, the latest, to look something up online, or to read a page or link.
tags: [web-search, news, read, grid]
triggers:
  - user asks for news / the latest / current events / today / recent
  - user asks to look up, search, or find something online
  - user gives a URL or asks you to read / open a page, article, or post
  - "tin tức", "tìm trên mạng", "đọc bài", "search the web", "read this", "what's the latest"
---

# Search and read the web

You can search the live web and read a specific page. No key, no setup — each
backend is provisioned on first run, then cached.

## Search — find pages and current info
```
"$uvPath" run --with ddgs python3 "$searchScriptPath" "<query>" [--max N]
```
Prints each result as three lines — title, URL, then a snippet — a blank line
between. `--max` caps the count (default 5).

## Read — the main text of one page
```
"$uvPath" run --with trafilatura python3 "$readScriptPath" "<url>" [--max-chars N]
```
Fetches the page and prints its main article text, boilerplate stripped. For a
page with no article body — a single X/Twitter post, or a JS-only page — it falls
back to the page's title and description, which for a tweet is the post text.

**Typical flow:** `search` to find URLs, then `read` the most relevant one for
detail. Answer in your own words and **cite the URLs** you used.

## What this can and can't do
- Reading ONE known URL — an article, or a specific tweet — works.
- Searching *inside* X/Twitter (every post about a topic) does **not**: X needs a
  login. Say so plainly if asked; don't pass a partial `site:x.com` search off as
  a complete one.

## If it fails
- Exit code 2 = a backend couldn't be provisioned (no `uv`/network). Tell the
  user web access isn't available right now.
- Exit code 1 on `read` = the page couldn't be fetched; try another source.
- Empty output = nothing found or readable; reword once, then say so.
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

/// Read one page's main text — no browser, so it can't run the JavaScript a
/// single-page app needs, but it reads a normal article outright and pulls a
/// tweet's text from its social metadata.
///
/// Run under `uv run --with trafilatura`, which fetches with sane headers,
/// strips a page to its article body, and — when there is none — exposes the
/// `og:`/`twitter:` title and description. That metadata path is why a specific
/// X/Twitter post reads without a login: the post text is the `og:description`.
const String kGridWebReadScript = r'''#!/usr/bin/env python3
"""Read the main text of a web page — no browser needed.

Meant to be run as:
    <uv> run --with trafilatura python3 read.py "<url>" [--max-chars N]
Prints the page's main article text (boilerplate removed). When there's no
article body — a single X/Twitter post, or a JS-only page — falls back to the
page's title and description (for a tweet, that's the post text). Exit 2 if the
reader is unavailable, 1 if the page couldn't be fetched.
"""

import argparse
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description="Read a web page's main text.")
    parser.add_argument("url", help="the page to read")
    parser.add_argument("--max-chars", type=int, default=6000, dest="max_chars")
    args = parser.parse_args()

    try:
        import trafilatura
    except ImportError:
        print("the page reader is not available", file=sys.stderr)
        return 2

    html = trafilatura.fetch_url(args.url)
    if not html:
        print("couldn't fetch the page", file=sys.stderr)
        return 1

    text = (
        trafilatura.extract(html, include_comments=False, include_tables=False)
        or ""
    )

    # Thin or login-walled page (a single tweet, a JS-only app): no article body,
    # but the social title/description carry the gist.
    if len(text.strip()) < 200:
        meta = trafilatura.extract_metadata(html)
        parts = []
        if meta is not None:
            if meta.title:
                parts.append(meta.title)
            if meta.description:
                parts.append(meta.description)
        if parts:
            text = "\n".join(parts)

    text = text.strip()
    if not text:
        print("No readable text found on the page.")
        return 0

    limit = max(500, args.max_chars)
    if len(text) > limit:
        text = f"{text[:limit]}\n…(truncated)"
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
''';
