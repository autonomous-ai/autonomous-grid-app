/// The tools Grid's own MCP server offers an agent, and the pure readers behind
/// them.
///
/// Two tools, both the live web through the grid: `web_search` and `web_fetch`.
/// They replace the `grid-web` scripts for Claude Code and Codex, whose own
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

const List<GridMcpTool> kGridMcpTools = [kGridWebSearchTool, kGridWebFetchTool];

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
