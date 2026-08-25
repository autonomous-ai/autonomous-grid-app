import 'dart:io';

import '../../../shared/skills/agent_skill_home.dart';

/// The one web-search skill every agent gets, so "search the news" works the same
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
/// `~/.grid/bin`, which every agent can already reach.
const String kGridWebSkillName = 'grid-web';

/// The absolute `uv` the skill drives — [gridSkillUvPath], shared with every other
/// Grid skill.
String gridWebUvPath() => gridSkillUvPath();

/// The `grid-web` skill as it lands in [skillDir]: the `SKILL.md` the agent reads
/// to know when and how to use it, plus the three scripts it runs (search, read
/// one page, and the heavy browser fallback).
///
/// The card names the scripts by absolute path, so it's a function of where the
/// skill lands — hence built from [skillDir] rather than a constant.
GridSkillFiles gridWebSkillFiles(Directory skillDir, {String? uvPath}) {
  final scripts = '${skillDir.path}/scripts';
  return GridSkillFiles(
    card: gridWebSkillMd(
      uvPath: uvPath ?? gridWebUvPath(),
      searchScriptPath: '$scripts/search.py',
      readScriptPath: '$scripts/read.py',
      browseScriptPath: '$scripts/browse.py',
    ),
    files: const {
      'scripts/search.py': kGridWebSearchScript,
      'scripts/read.py': kGridWebReadScript,
      'scripts/browse.py': kGridWebBrowseScript,
    },
  );
}

/// The skill card every agent reads. Only the `name`/`description` frontmatter
/// decides *when* it triggers, so those carry the intent; the body is loaded only
/// once it fires and spells out the two commands — search, and read one page.
String gridWebSkillMd({
  required String uvPath,
  required String searchScriptPath,
  required String readScriptPath,
  required String browseScriptPath,
}) =>
    '''
---
name: $kGridWebSkillName
description: Search the web and read pages for current, live, or online information — news, recent events, prices, today's facts, a specific article or post, anything past your training. Use whenever the user asks about what's happening now, the latest, to look something up or find something online, or when they give you a URL or ask you to read or open a page, article or post. "the news", "look it up online", "read this article", "search the web", "read this", "what's the latest".
---

# Search and read the web

You can search the live web and read a specific page. No key, no setup.

## Search — find pages and current info
```
python3 "$searchScriptPath" "<query>" [--max N]
```
The search runs on your grid, not on this machine. Prints each result as three
lines — title, URL, then an excerpt chosen for your query — a blank line
between. `--max` caps the count (default 5).

## Read — the main text of one page
```
"$uvPath" run --with trafilatura python3 "$readScriptPath" "<url>" [--max-chars N]
```
Fetches the page and prints its main article text, boilerplate stripped. For a
page with no article body — a single X/Twitter post, or a JS-only page — it falls
back to the page's title and description, which for a tweet is the post text.

## Browse — a real browser, for a page `read` couldn't get
Only when `read` came back empty or too thin because the page builds itself with
JavaScript (a web app), or blocked the plain fetch. Heavier — it drives a real
headless browser — so try `read` first every time.
```
"$uvPath" run --with playwright --with trafilatura python3 "$browseScriptPath" "<url>" [--max-chars N]
```
If it exits 3 (`the browser isn't installed yet`), the browser needs a one-time
download (~170MB). Tell the user that, run it **once**, then retry the browse:
```
"$uvPath" run --with playwright playwright install chromium
```

**Typical flow:** `search` to find URLs, then `read` the most relevant one; only
reach for `browse` when `read` couldn't. Answer in your own words and **cite the
URLs** you used.

## What this can and can't do
- Reading ONE known URL — an article, or a specific tweet — works.
- Searching *inside* X/Twitter (every post about a topic) does **not**: X needs a
  login. Say so plainly if asked; don't pass a partial `site:x.com` search off as
  a complete one.

## If it fails
Every failure prints one sentence saying what to do. Read it and say it to the
user — don't retry a command that told you why it won't work.
- `search` exit 2 = web search isn't available here (no grid, or this grid's
  relay is too old). Tell the user what the message said.
- `search` exit 1 = it failed this time. If the message says the search is
  busy, wait a few seconds and try **once** more, never in a loop.
- Exit code 2 on `read`/`browse` = a backend couldn't be provisioned (no
  `uv`/network). Tell the user page reading isn't available right now.
- Exit code 1 on `read`/`browse` = the page couldn't be fetched; try another
  source.
- Exit code 3 on `browse` = one-time browser download needed (see above).
- `No results.` = nothing found; reword once, then say so. It is not an error,
  and it is never what a refusal looks like — those print a sentence and exit
  non-zero.
''';

/// The search itself: a POST to this grid's relay, which forwards it to the
/// control plane — the only thing holding the search vendor's key.
///
/// **Standard library only.** No package runner, no on-demand download, and no
/// DuckDuckGo: the first web question of a fresh install now answers as fast as
/// the tenth, and the rate limit that used to cut a research question in half
/// belonged to the user's own address and is gone with it.
///
/// It reads exactly two variables — `GRID_RELAY_URL` and `GRID_RELAY_TOKEN`,
/// which the app sets in the environment of every agent it spawns. It reads **no** credential file and, deliberately,
/// none of the vendor variables that are already in that environment: the app's
/// own process can be carrying an `ANTHROPIC_*` a developer exported, so a
/// script reading one of those names could pick up a person's real vendor key
/// and post it to a relay.
const String kGridWebSearchScript = r'''#!/usr/bin/env python3
"""Search the live web through your grid.

    python3 search.py "<query>" [--max N]

Standard library only — nothing to install. The grid's relay holds the
credential; this script holds none. Prints one result per block:
    title
    url
    excerpt
(blank line between).

Exit codes:
    0  it worked (possibly with no results, which prints "No results.")
    1  the search failed this time — the message says what to do
    2  web search is not available here — the message says why
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

RELAY_URL_VAR = "GRID_RELAY_URL"
RELAY_TOKEN_VAR = "GRID_RELAY_TOKEN"
SEARCH_PATH = "/web/search"

# Generous: a search is a third party crawling the live web, behind two hops.
# Finite: an agent is waiting inside somebody's turn.
TIMEOUT_SECONDS = 60

NO_GRID = (
    "Web search needs a grid. Open Grid, pick or create a grid, then try again."
)
OLD_RELAY = (
    "This grid cannot search the web yet: its relay does not serve "
    + SEARCH_PATH
    + ". Ask whoever runs the grid to update it."
)
REFUSED = (
    "This grid refused the credential. In Grid, switch grids and back, or sign "
    "out and in again."
)


def main() -> int:
    parser = argparse.ArgumentParser(description="Search the web through your grid.")
    parser.add_argument("query", help="what to search for")
    parser.add_argument("--max", type=int, default=5, dest="max_results")
    args = parser.parse_args()

    base = (os.environ.get(RELAY_URL_VAR) or "").strip()
    token = (os.environ.get(RELAY_TOKEN_VAR) or "").strip()
    if not base or not token:
        print(NO_GRID, file=sys.stderr)
        return 2

    body = json.dumps(
        {"query": args.query, "num_results": max(1, args.max_results)}
    ).encode("utf-8")
    request = urllib.request.Request(
        base.rstrip("/") + SEARCH_PATH,
        data=body,
        headers={
            "Authorization": "Bearer " + token,
            "Content-Type": "application/json",
        },
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
            payload = json.loads(response.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as error:
        return refused(error)
    except (urllib.error.URLError, OSError) as error:
        print("couldn't reach the grid: %s" % error, file=sys.stderr)
        return 1
    except ValueError:
        print("the grid answered with something that isn't a search result",
              file=sys.stderr)
        return 1

    results = payload.get("results") if isinstance(payload, dict) else None
    if not isinstance(results, list):
        print("the grid answered with something that isn't a search result",
              file=sys.stderr)
        return 1
    if not results:
        print("No results.")
        return 0

    for row in results:
        if not isinstance(row, dict):
            continue
        title = str(row.get("title") or "").strip()
        url = str(row.get("url") or "").strip()
        excerpt = str(row.get("excerpt") or "").strip()
        print("%s\n%s\n%s\n" % (title, url, excerpt))
    return 0


def refused(error) -> int:
    """Turn a refusal into one sentence the agent can act on.

    Every one of these has to be distinguishable from "I found nothing", which
    is a perfectly good exit 0 above — an agent that reported an empty result
    when it was actually turned away would be reporting a fact that is not true.
    """
    if error.code == 404:
        print(OLD_RELAY, file=sys.stderr)
        return 2
    if error.code in (401, 403):
        print(REFUSED, file=sys.stderr)
        return 2
    sentence = detail(error)
    print(sentence, file=sys.stderr)
    # 503 is the grid saying it cannot search at all; everything else, 429
    # included, is worth one more try later in the same turn.
    return 2 if error.code == 503 else 1


def detail(error) -> str:
    """The sentence the far side sent, or a plain one when it sent none."""
    try:
        payload = json.loads(error.read().decode("utf-8", "replace"))
        sentence = payload.get("detail") if isinstance(payload, dict) else None
        if isinstance(sentence, str) and sentence.strip():
            return sentence.strip()
    except Exception:  # noqa: BLE001 - a refusal we cannot read is still a refusal
        pass
    return "the search was refused (HTTP %s)" % error.code


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

/// Read a page a plain fetch can't: one that renders with JavaScript, or blocks
/// non-browser requests. The heavy fallback behind `read` — it drives a real
/// headless Chromium via Playwright, so the app keeps it off the default install
/// and lets it pull the browser on first use.
///
/// Run under `uv run --with playwright --with trafilatura`. The `playwright`
/// package comes on demand, but the ~170MB Chromium binary does not — so a launch
/// on a machine that has never downloaded it exits 3 with the one-time
/// `playwright install chromium` to run, rather than blocking a turn on a silent
/// download. Renders the page, then hands the HTML to trafilatura for the same
/// clean extraction `read` uses, falling back to the body's visible text.
const String kGridWebBrowseScript = r'''#!/usr/bin/env python3
"""Read a JavaScript-rendered or bot-blocked page with a real browser.

Heavier than read.py — use only when read.py came back empty or too thin. Run as:
    <uv> run --with playwright --with trafilatura python3 browse.py "<url>" [--max-chars N]

Exit codes: 0 ok, 1 the page wouldn't load, 2 Playwright unavailable,
3 the browser isn't downloaded yet (run `playwright install chromium` once).
"""

import argparse
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description="Read a JS-rendered page.")
    parser.add_argument("url", help="the page to read")
    parser.add_argument("--max-chars", type=int, default=6000, dest="max_chars")
    args = parser.parse_args()

    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        print("the browser reader is not available", file=sys.stderr)
        return 2

    html = ""
    body_text = ""
    try:
        with sync_playwright() as play:
            try:
                browser = play.chromium.launch(headless=True)
            except Exception as exc:  # noqa: BLE001 - classify missing browser
                low = str(exc).lower()
                if "executable doesn't exist" in low or "playwright install" in low:
                    print(
                        "the browser isn't installed yet — run once: "
                        "playwright install chromium",
                        file=sys.stderr,
                    )
                    return 3
                raise
            try:
                page = browser.new_page()
                page.goto(args.url, wait_until="domcontentloaded", timeout=25000)
                # Give client-side rendering a beat to settle; some pages never go
                # idle, so a timeout here is fine, not a failure.
                try:
                    page.wait_for_load_state("networkidle", timeout=8000)
                except Exception:  # noqa: BLE001
                    pass
                html = page.content()
                try:
                    body_text = page.inner_text("body")
                except Exception:  # noqa: BLE001
                    body_text = ""
            finally:
                browser.close()
    except Exception as exc:  # noqa: BLE001 - any load failure
        print(
            f"couldn't load the page: {str(exc).splitlines()[0][:180]}",
            file=sys.stderr,
        )
        return 1

    text = ""
    try:
        import trafilatura

        text = (
            trafilatura.extract(html, include_comments=False, include_tables=False)
            or ""
        )
    except ImportError:
        pass
    # No article body — fall back to the rendered visible text of the page.
    if len(text.strip()) < 120:
        text = body_text

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
