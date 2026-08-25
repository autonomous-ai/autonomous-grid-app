import 'dart:io';

import '../../../shared/skills/agent_skill_home.dart';

/// The one web skill every agent gets, so "search the news" and "read this
/// article" work the same whichever is answering.
///
/// Codex on a grid has **no** web search of its own — its `web_search` is an
/// OpenAI-Responses server-side tool the grid relay doesn't serve — so a skill is
/// the only way to give it one. Hermes has a native `web_search` too (see
/// [ensureHermesWebSearch]); it gets the same skill so the two behave alike.
///
/// **Both scripts run on the grid, and both are standard library only.**
/// Searching and reading go to this grid's relay, which forwards to the control
/// plane — the only thing holding the vendor's key. Nothing is provisioned on the
/// user's machine any more: no package runner, no on-demand package fetch, and no
/// ~170 MB browser download asked for in the middle of an answer.
const String kGridWebSkillName = 'grid-web';

/// The `grid-web` skill as it lands in [skillDir]: the `SKILL.md` the agent reads
/// to know when and how to use it, plus the two scripts it runs — search, and
/// read one page.
///
/// The card names the scripts by absolute path, so it's a function of where the
/// skill lands — hence built from [skillDir] rather than a constant.
GridSkillFiles gridWebSkillFiles(Directory skillDir) {
  final scripts = '${skillDir.path}/scripts';
  return GridSkillFiles(
    card: gridWebSkillMd(
      searchScriptPath: '$scripts/search.py',
      readScriptPath: '$scripts/read.py',
    ),
    files: const {
      'scripts/search.py': kGridWebSearchScript,
      'scripts/read.py': kGridWebReadScript,
    },
  );
}

/// The skill card every agent reads. Only the `name`/`description` frontmatter
/// decides *when* it triggers, so those carry the intent; the body is loaded only
/// once it fires and spells out the two commands — search, and read one page.
String gridWebSkillMd({
  required String searchScriptPath,
  required String readScriptPath,
}) =>
    '''
---
name: $kGridWebSkillName
description: Search the web and read pages for current, live, or online information — news, recent events, prices, today's facts, a specific article or post, anything past your training. Use whenever the user asks about what's happening now, the latest, to look something up or find something online, or when they give you a URL or ask you to read or open a page, article or post. "the news", "look it up online", "read this article", "search the web", "read this", "what's the latest".
---

# Search and read the web

You can search the live web and read a specific page. No key, no setup, nothing
to install — both run on your grid.

## Search — find pages and current info
```
python3 "$searchScriptPath" "<query>" [--max N]
```
Prints each result as three lines — title, URL, then an excerpt chosen for your
query — a blank line between. `--max` caps the count (default 5).

## Read — the main text of one page
```
python3 "$readScriptPath" "<url>" [--max-chars N]
```
Prints the page's main article text, boilerplate stripped. A page that builds
itself with JavaScript reads the same way as any other — there is no second
command and nothing to download.

**Typical flow:** `search` to find URLs, then `read` the most relevant one.
Answer in your own words and **cite the URLs** you used.

## What this can and can't do
- Reading ONE known URL — an article, or a specific tweet — works.
- Searching *inside* X/Twitter (every post about a topic) does **not**: X needs a
  login. Say so plainly if asked; don't pass a partial `site:x.com` search off as
  a complete one.
- A page only this machine can reach — something on localhost or a private
  network — is **not** what these are for. Use your shell for that.

## If it fails
Every failure prints one sentence saying what to do. Read it and say it to the
user — don't retry a command that told you why it won't work.
- Exit 2 = not available here, or not for a while (no grid, a relay too old, a
  credential the grid refused, or the account's **daily allowance** is spent —
  the message says which, and when an allowance returns). Tell the user what it
  said and do **not** run the command again in this turn.
- Exit 1 = it failed this time. If the message says the web is busy, wait a few
  seconds and try **once** more, never in a loop. If a page couldn't be read,
  try another source.
- `No results.` / `No readable text found on the page.` = nothing was there. It
  is not an error, it is never what a refusal looks like — those print a
  sentence and exit non-zero — and it is never what a page that *refused* looks
  like either, which says so and exits 1.
''';

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
    2  web search is not available here, or not for a while — the message says
       why. Never worth retrying in this turn.
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

# The control plane's daily per-account allowance, spent. Compared for EQUALITY
# and never matched on the sentence beside it, which is the far side's to reword.
# A 429 without it is the search vendor turning the fleet away for a few seconds,
# which is the opposite advice — hence a code rather than two status codes.
ALLOWANCE_CODE = "web_search_allowance_exhausted"


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

    The exit code is the part an agent acts on without reading: 1 says the same
    command is worth trying once more later in this turn, 2 says it is not.
    """
    if error.code == 404:
        print(OLD_RELAY, file=sys.stderr)
        return 2
    if error.code in (401, 403):
        print(REFUSED, file=sys.stderr)
        return 2
    payload = body(error)
    print(sentence(payload, error.code), file=sys.stderr)
    # Two refusals share 429, and they want opposite things. The vendor turning
    # the whole fleet away lifts in seconds and is worth one more try; a spent
    # daily allowance lifts in hours and is not. Only the second carries a code,
    # so a relay too old to forward it degrades to "try once more" — the wrong
    # advice, but with the sentence still saying plainly why. 503 is the grid
    # saying it cannot search at all.
    if error.code == 503 or payload.get("code") == ALLOWANCE_CODE:
        return 2
    return 1


def body(error) -> dict:
    """The refusal's JSON object, or an empty one.

    Read exactly once: an HTTP error is a stream, and a second `.read()` of it
    answers empty — so the sentence and the code have to come out together.
    """
    try:
        payload = json.loads(error.read().decode("utf-8", "replace"))
    except Exception:  # noqa: BLE001 - a refusal we cannot read is still a refusal
        return {}
    return payload if isinstance(payload, dict) else {}


def sentence(payload, code) -> str:
    """The sentence the far side sent, or a plain one when it sent none."""
    text = payload.get("detail")
    if isinstance(text, str) and text.strip():
        return text.strip()
    return "the search was refused (HTTP %s)" % code


if __name__ == "__main__":
    sys.exit(main())
''';

/// Read one page's main text, through the grid.
///
/// **Standard library only**, like the search beside it. The page is fetched and
/// extracted by the vendor the control plane pays, so a page that builds itself
/// with JavaScript reads exactly like a static article — which is what let the
/// browser fallback, its ~170 MB Chromium download and the exit code that asked
/// for one all be deleted.
///
/// ⚠️ **A page that refused is not a page with nothing on it.** The reply carries
/// a status per URL, and this script keeps the two apart: an agent told "there is
/// nothing on that page" about a page that turned it away reports a fact that is
/// not true, in a confident voice.
///
/// The duplication with [kGridWebSearchScript] — the two variables, the refusal
/// map — is deliberate: these are standalone files an agent runs by absolute
/// path, and a shared module beside them would be a third file the guides do not
/// name and an import path they would have to agree on.
const String kGridWebReadScript = r'''#!/usr/bin/env python3
"""Read the main text of a web page, through your grid.

    python3 read.py "<url>" [--max-chars N]

Standard library only — nothing to install. The grid's relay holds the
credential; this script holds none. A page that builds itself with JavaScript
reads the same way as any other.

Exit codes:
    0  it worked (a page with nothing on it prints "No readable text found on
       the page.", which is not an error)
    1  it failed this time — the page could not be read, or the web is busy
    2  reading is not available here, or not for a while — the message says why.
       Never worth retrying in this turn.
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

RELAY_URL_VAR = "GRID_RELAY_URL"
RELAY_TOKEN_VAR = "GRID_RELAY_TOKEN"
CONTENTS_PATH = "/web/contents"

# Generous: a read is a third party fetching and rendering a live page, behind
# two hops. Finite: an agent is waiting inside somebody's turn.
TIMEOUT_SECONDS = 60

# Below this the answer is a stub rather than a page, but it is still an answer.
MIN_CHARS = 500

NO_GRID = (
    "Reading a page needs a grid. Open Grid, pick or create a grid, then try "
    "again."
)
OLD_RELAY = (
    "This grid cannot read pages yet: its relay does not serve "
    + CONTENTS_PATH
    + ". Ask whoever runs the grid to update it."
)
REFUSED = (
    "This grid refused the credential. In Grid, switch grids and back, or sign "
    "out and in again."
)

# The control plane's daily per-account allowance, spent — shared with search,
# because both cost the operator money at the same vendor. Compared for EQUALITY
# and never matched on the sentence beside it, which is the far side's to reword.
# A 429 without it is the vendor turning the fleet away for a few seconds, which
# is the opposite advice — hence a code rather than two status codes.
ALLOWANCE_CODE = "web_search_allowance_exhausted"

# What the far side says about a page it could not fetch.
STATUS_ERROR = "error"


def main() -> int:
    parser = argparse.ArgumentParser(description="Read a web page's main text.")
    parser.add_argument("url", help="the page to read")
    parser.add_argument("--max-chars", type=int, default=6000, dest="max_chars")
    args = parser.parse_args()

    base = (os.environ.get(RELAY_URL_VAR) or "").strip()
    token = (os.environ.get(RELAY_TOKEN_VAR) or "").strip()
    if not base or not token:
        print(NO_GRID, file=sys.stderr)
        return 2

    body = json.dumps({"urls": [args.url]}).encode("utf-8")
    request = urllib.request.Request(
        base.rstrip("/") + CONTENTS_PATH,
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
        return unreadable()

    results = payload.get("results") if isinstance(payload, dict) else None
    if not isinstance(results, list) or not results:
        # The far side answers one entry per URL asked for, so an empty list is
        # a broken seam and never a blank page.
        return unreadable()
    page = results[0]
    if not isinstance(page, dict):
        return unreadable()

    # A page that REFUSED is not a page with nothing on it. Reporting the second
    # for the first tells the user there is nothing there, which is false, and
    # they have no way to know it.
    if str(page.get("status") or "").strip() == STATUS_ERROR:
        reason = str(page.get("error") or "").strip() or "the page was not returned"
        print("couldn't read the page: %s" % reason, file=sys.stderr)
        return 1

    text = str(page.get("text") or "").strip()
    if not text:
        print("No readable text found on the page.")
        return 0

    limit = max(MIN_CHARS, args.max_chars)
    if len(text) > limit:
        text = "%s\n\u2026(truncated)" % text[:limit]
    print(text)
    return 0


def unreadable() -> int:
    """The grid answered something that is not a page. Never an empty page: an
    agent that reported one would be reporting a fact it was never given."""
    print("the grid answered with something that isn't a page", file=sys.stderr)
    return 1


def refused(error) -> int:
    """Turn a refusal into one sentence the agent can act on.

    Every one of these has to be distinguishable from a page with nothing on it,
    which is a perfectly good exit 0 above.

    The exit code is the part an agent acts on without reading: 1 says the same
    command is worth trying once more later in this turn, 2 says it is not.
    """
    if error.code == 404:
        print(OLD_RELAY, file=sys.stderr)
        return 2
    if error.code in (401, 403):
        print(REFUSED, file=sys.stderr)
        return 2
    payload = body(error)
    print(sentence(payload, error.code), file=sys.stderr)
    # Two refusals share 429 and want opposite things. The vendor turning the
    # whole fleet away lifts in seconds and is worth one more try; a spent daily
    # allowance lifts in hours and is not. Only the second carries a code, so a
    # relay too old to forward it degrades to "try once more" — the wrong advice,
    # but with the sentence still saying plainly why. 503 is the grid saying it
    # cannot reach the thing that reads pages at all.
    if error.code == 503 or payload.get("code") == ALLOWANCE_CODE:
        return 2
    return 1


def body(error) -> dict:
    """The refusal's JSON object, or an empty one.

    Read exactly once: an HTTP error is a stream, and a second `.read()` of it
    answers empty — so the sentence and the code have to come out together.
    """
    try:
        payload = json.loads(error.read().decode("utf-8", "replace"))
    except Exception:  # noqa: BLE001 - a refusal we cannot read is still a refusal
        return {}
    return payload if isinstance(payload, dict) else {}


def sentence(payload, code) -> str:
    """The sentence the far side sent, or a plain one when it sent none."""
    text = payload.get("detail")
    if isinstance(text, str) and text.strip():
        return text.strip()
    return "reading the page was refused (HTTP %s)" % code


if __name__ == "__main__":
    sys.exit(main())
''';
