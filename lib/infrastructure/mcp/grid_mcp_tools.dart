/// The tools Grid's own MCP server offers an agent, and the pure readers behind
/// them.
///
/// Two families. The **web** — `web_search` and `web_fetch`, the live web
/// through the grid, which every chat gets. And the **browser** — seven tools
/// that drive the Browser tab the user has open, offered only when the user has
/// picked that browser (see [kGridBrowserTools]).
///
/// The web pair replace the `grid-web` scripts for Claude Code and Codex,
/// whose own
/// `WebSearch`/`WebFetch` are served by their vendor and refused by a relay
/// (see `kClaudeServerWebTools`) — and they replace `grid_ask` / `grid_guide`,
/// switched off on 2026-08-27: a guide that pointed at a Python script was one
/// more hop for the model to fall off (it did — an SSL failure in the script
/// and a helper it wrote itself), where a tool is the thing itself.
library;

import '../api/relay_web_client.dart';

class GridMcpTool {
  const GridMcpTool({
    required this.name,
    required this.description,
    required this.schema,
  });

  final String name;

  /// What the agent reads to decide whether to call it.
  final String description;

  /// JSON Schema of the arguments.
  final Map<String, Object?> schema;

  Map<String, Object?> toJson() => {
    'name': name,
    'description': description,
    'inputSchema': schema,
  };
}

/// How many hits a search returns unless asked otherwise, and the most it will.
const int kWebSearchDefaultResults = 5;
const int kWebSearchMaxResults = 10;

/// How much of a page a fetch returns unless asked otherwise, and the least
/// worth asking for — below it the agent sees a headline and no article.
const int kWebFetchDefaultChars = 6000;
const int kWebFetchMinChars = 500;

const GridMcpTool kGridWebSearchTool = GridMcpTool(
  name: 'web_search',
  description:
      'Search the live web through the grid. Use it whenever the answer '
      'depends on anything current — news, prices, recent events, a fact '
      'past your training — or the user asks you to look something up. '
      'Returns the top hits as title, URL and excerpt; call web_fetch on a '
      'URL to read the page itself. Nothing to install and no key: it runs on '
      'your grid.',
  schema: {
    'type': 'object',
    'properties': {
      'query': {'type': 'string', 'description': 'What to search for.'},
      'max_results': {
        'type': 'integer',
        'description':
            'How many hits to return (default $kWebSearchDefaultResults, at '
            'most $kWebSearchMaxResults).',
      },
    },
    'required': ['query'],
  },
);

const GridMcpTool kGridWebFetchTool = GridMcpTool(
  name: 'web_fetch',
  description:
      'Read the main text of a web page through the grid — an article, a '
      'post, a search hit worth reading in full. A page that builds itself '
      'with JavaScript reads the same as any other. Returns the readable '
      'text, cut to max_chars.',
  schema: {
    'type': 'object',
    'properties': {
      'url': {'type': 'string', 'description': 'The page to read.'},
      'max_chars': {
        'type': 'integer',
        'description':
            'How much text to return (default $kWebFetchDefaultChars, never '
            'less than $kWebFetchMinChars).',
      },
    },
    'required': ['url'],
  },
);

/// The web tools, which every chat gets.
const List<GridMcpTool> kGridWebTools = [kGridWebSearchTool, kGridWebFetchTool];

/// The arguments of one `web_search` call, or null when there is no query —
/// the one thing the call cannot do without.
({String query, int maxResults})? readWebSearchArgs(Object? arguments) {
  if (arguments is! Map) return null;
  final query = arguments['query'];
  if (query is! String || query.trim().isEmpty) return null;
  final asked = arguments['max_results'];
  final max = asked is num ? asked.toInt() : kWebSearchDefaultResults;
  return (query: query.trim(), maxResults: max.clamp(1, kWebSearchMaxResults));
}

/// The arguments of one `web_fetch` call, or null when there is no URL.
({String url, int maxChars})? readWebFetchArgs(Object? arguments) {
  if (arguments is! Map) return null;
  final url = arguments['url'];
  if (url is! String || url.trim().isEmpty) return null;
  final asked = arguments['max_chars'];
  final max = asked is num ? asked.toInt() : kWebFetchDefaultChars;
  return (
    url: url.trim(),
    maxChars: max < kWebFetchMinChars ? kWebFetchMinChars : max,
  );
}

/// Search hits as the agent reads them: one block per hit — title, URL,
/// excerpt — with a blank line between, the shape `search.py` printed.
String formatWebSearchHits(List<WebSearchHit> hits) {
  if (hits.isEmpty) return 'No results.';
  return [
    for (final hit in hits) '${hit.title}\n${hit.url}\n${hit.excerpt}',
  ].join('\n\n');
}

/// A page as the agent reads it: its text, cut at [maxChars] and saying so.
String formatWebPage(WebPage page, {required int maxChars}) {
  if (page.text.isEmpty) return 'No readable text found on the page.';
  final body = page.text.length <= maxChars
      ? page.text
      : '${page.text.substring(0, maxChars)}\n…(truncated)';
  return page.title.isEmpty ? body : '${page.title}\n\n$body';
}

/// How much of a page `browser_read` returns unless asked otherwise.
const int kBrowserReadDefaultChars = 8000;

const GridMcpTool kBrowserSnapshotTool = GridMcpTool(
  name: 'browser_snapshot',
  description:
      'Read the page open in the user\'s Grid browser tab as a tree of roles, '
      'names and refs — buttons, links, form fields. Call this before every '
      'click or type: a ref belongs to the page it was read from, and goes '
      'stale the moment the page changes. Use browser_read instead when you '
      'only want the text of an article.',
  schema: {'type': 'object', 'properties': <String, Object?>{}},
);

const GridMcpTool kBrowserReadTool = GridMcpTool(
  name: 'browser_read',
  description:
      'Read the text of the page open in the user\'s Grid browser tab. Use it '
      'for anything the user is already looking at, and for pages web_fetch '
      'cannot reach because they are behind a login — this tab is signed in as '
      'the user.',
  schema: {
    'type': 'object',
    'properties': {
      'max_chars': {
        'type': 'integer',
        'description':
            'How much text to return (default $kBrowserReadDefaultChars).',
      },
    },
  },
);

const GridMcpTool kBrowserNavigateTool = GridMcpTool(
  name: 'browser_navigate',
  description:
      'Open a URL in the user\'s Grid browser tab, opening the tab if it is '
      'not already there. Waits for the page to load and reports where it '
      'landed. Prefer web_fetch for reading a public page you were given the '
      'address of; use this when you need the page itself — to sign in as the '
      'user, fill a form, or click through something.',
  schema: {
    'type': 'object',
    'properties': {
      'url': {'type': 'string', 'description': 'The address to open.'},
    },
    'required': ['url'],
  },
);

const GridMcpTool kBrowserClickTool = GridMcpTool(
  name: 'browser_click',
  description:
      'Click an element in the user\'s Grid browser tab by the ref a '
      'browser_snapshot gave it. Waits for any page change the click causes.',
  schema: {
    'type': 'object',
    'properties': {
      'ref': {
        'type': 'string',
        'description': 'The ref from the last snapshot, e.g. "e12".',
      },
    },
    'required': ['ref'],
  },
);

const GridMcpTool kBrowserTypeTool = GridMcpTool(
  name: 'browser_type',
  description:
      'Type into an input in the user\'s Grid browser tab by the ref a '
      'browser_snapshot gave it. Replaces whatever is in the field. Set submit '
      'to press Enter afterwards, which is how a search box is used.',
  schema: {
    'type': 'object',
    'properties': {
      'ref': {
        'type': 'string',
        'description': 'The ref from the last snapshot, e.g. "e4".',
      },
      'text': {'type': 'string', 'description': 'What to put in the field.'},
      'submit': {
        'type': 'boolean',
        'description': 'Press Enter after typing. Default false.',
      },
    },
    'required': ['ref', 'text'],
  },
);

const GridMcpTool kBrowserBackTool = GridMcpTool(
  name: 'browser_back',
  description: 'Go back one page in the user\'s Grid browser tab.',
  schema: {'type': 'object', 'properties': <String, Object?>{}},
);

const GridMcpTool kBrowserScreenshotTool = GridMcpTool(
  name: 'browser_screenshot',
  description:
      'Take a picture of the page open in the user\'s Grid browser tab. Use it '
      'only when the snapshot is not enough — a chart, a layout problem, '
      'something drawn on a canvas. The snapshot is cheaper and is what you '
      'click by.',
  schema: {'type': 'object', 'properties': <String, Object?>{}},
);

/// The tools that drive the user's Browser tab.
///
/// Offered **only** when the user has picked that browser
/// (`AgentBrowserChoice.gridTab`): the server leaves them out of `tools/list`
/// otherwise, so an agent is never told about a door it will then be refused
/// at. Every one of them acts in a tab signed in as the user, which is why the
/// switch is a switch and not a default.
const List<GridMcpTool> kGridBrowserTools = [
  kBrowserSnapshotTool,
  kBrowserReadTool,
  kBrowserNavigateTool,
  kBrowserClickTool,
  kBrowserTypeTool,
  kBrowserBackTool,
  kBrowserScreenshotTool,
];

/// The arguments of one `browser_read` call.
int readBrowserReadChars(Object? arguments) {
  final asked = arguments is Map ? arguments['max_chars'] : null;
  final max = asked is num ? asked.toInt() : kBrowserReadDefaultChars;
  return max < kWebFetchMinChars ? kWebFetchMinChars : max;
}

/// The ref one browser call names, or null when it named none — every acting
/// tool needs one, and acting on "whatever is focused" is not something an
/// agent should be able to ask for by omission.
String? readBrowserRef(Object? arguments) {
  if (arguments is! Map) return null;
  final ref = arguments['ref'];
  return ref is String && ref.trim().isNotEmpty ? ref.trim() : null;
}

/// The arguments of one `browser_type` call, or null without a ref or text.
({String ref, String text, bool submit})? readBrowserTypeArgs(
  Object? arguments,
) {
  final ref = readBrowserRef(arguments);
  if (ref == null || arguments is! Map) return null;
  final text = arguments['text'];
  if (text is! String) return null;
  return (ref: ref, text: text, submit: arguments['submit'] == true);
}

/// The URL one `browser_navigate` call names, or null when it named none.
String? readBrowserUrl(Object? arguments) {
  if (arguments is! Map) return null;
  final url = arguments['url'];
  return url is String && url.trim().isNotEmpty ? url.trim() : null;
}
