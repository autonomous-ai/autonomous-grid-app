import 'dart:convert';
import 'dart:io';

/// One hit from a web search the grid ran on the agent's behalf.
typedef WebSearchHit = ({String title, String url, String excerpt});

/// The readable text of one page the grid fetched, with the title it found.
typedef WebPage = ({String title, String text});

/// The relay turned the request away, in a sentence the agent can act on.
///
/// [retryable] is the part an agent acts on without reading: a vendor turning
/// the whole fleet away lifts in seconds and is worth one more try; a spent
/// daily allowance, an old relay, or a refused credential are not.
class RelayWebRefused implements Exception {
  const RelayWebRefused(this.message, {required this.retryable});

  final String message;
  final bool retryable;

  @override
  String toString() => 'RelayWebRefused($message)';
}

/// The live web, through the grid's relay — the same two endpoints the
/// `search.py` / `read.py` scripts post to, spoken from the app instead.
///
/// Behind an interface so the MCP server is tested against a fake: the tests
/// are offline, and the real thing needs a grid.
abstract interface class RelayWebClient {
  Future<List<WebSearchHit>> search({
    required String baseUrl,
    required String apiKey,
    required String query,
    required int maxResults,
  });

  Future<WebPage> read({
    required String baseUrl,
    required String apiKey,
    required String url,
  });
}

/// Where the relay serves search and page-reading, under its `/v1` base.
const String kRelayWebSearchPath = '/web/search';
const String kRelayWebContentsPath = '/web/contents';

/// The relay's code for a daily search allowance that is spent — a 429 that
/// lifts in hours, unlike the vendor's, which lifts in seconds.
const String kRelayWebAllowanceCode = 'web_search_allowance_exhausted';

/// Long enough for a page that builds itself with JavaScript to be rendered on
/// the far side; the scripts wait the same.
const Duration kRelayWebDeadline = Duration(seconds: 60);

/// The sentence for a relay that refused, by status — the same three the
/// scripts print, so a user who has read one of them recognises the other.
///
/// Pure, and unit-tested: this is the wire contract with the relay, and a
/// status read wrong tells the user to sign out for a page that was merely
/// slow.
RelayWebRefused relayWebRefusal(
  int status,
  Object? body, {
  required String action,
}) {
  final payload = body is Map ? body : const {};
  return switch (status) {
    404 => RelayWebRefused(
      'This grid cannot $action yet: its relay does not serve it. Ask whoever '
      'runs the grid to update it.',
      retryable: false,
    ),
    401 || 403 => const RelayWebRefused(
      'This grid refused the credential. In Grid, switch grids and back, or '
      'sign out and in again.',
      retryable: false,
    ),
    _ => RelayWebRefused(
      _detail(payload) ?? 'the request was refused (HTTP $status)',
      // 503 is the grid saying it cannot do this at all; a spent allowance
      // says so by code. Everything else — the vendor's own 429 included —
      // is worth one more try later in the turn.
      retryable: status != 503 && payload['code'] != kRelayWebAllowanceCode,
    ),
  };
}

String? _detail(Map<Object?, Object?> payload) {
  final detail = payload['detail'];
  return detail is String && detail.trim().isNotEmpty ? detail.trim() : null;
}

/// The hits in a `/web/search` reply, or null when the body is not one.
///
/// Null rather than empty on a shape we don't recognise: an agent told "no
/// results" for a reply it was never given would report a fact that isn't so.
List<WebSearchHit>? webSearchHitsFromJson(Object? decoded) {
  if (decoded is! Map) return null;
  final rows = decoded['results'];
  if (rows is! List) return null;
  return [
    for (final row in rows)
      if (row is Map)
        (
          title: '${row['title'] ?? ''}'.trim(),
          url: '${row['url'] ?? ''}'.trim(),
          excerpt: '${row['excerpt'] ?? ''}'.trim(),
        ),
  ];
}

/// The first page in a `/web/contents` reply — one is asked for — or null
/// when the body is not one. A page the far side could not fetch comes back
/// with a status of `error`, and that is [RelayWebRefused], never an empty
/// page: reporting nothing there for a page that refused tells the user there
/// is nothing there, which is false.
WebPage? webPageFromJson(Object? decoded) {
  if (decoded is! Map) return null;
  final rows = decoded['results'];
  if (rows is! List || rows.isEmpty) return null;
  final page = rows.first;
  if (page is! Map) return null;
  if ('${page['status'] ?? ''}'.trim() == 'error') {
    final reason = '${page['error'] ?? ''}'.trim();
    throw RelayWebRefused(
      "couldn't read the page: "
      '${reason.isEmpty ? 'the page was not returned' : reason}',
      retryable: true,
    );
  }
  return (
    title: '${page['title'] ?? ''}'.trim(),
    text: '${page['text'] ?? ''}'.trim(),
  );
}

/// Real implementation: two POSTs with the grid's bearer token.
class HttpRelayWebClient implements RelayWebClient {
  const HttpRelayWebClient();

  @override
  Future<List<WebSearchHit>> search({
    required String baseUrl,
    required String apiKey,
    required String query,
    required int maxResults,
  }) async {
    final decoded = await _post(
      Uri.parse('$baseUrl$kRelayWebSearchPath'),
      apiKey,
      {'query': query, 'num_results': maxResults},
      action: 'search the web',
    );
    final hits = webSearchHitsFromJson(decoded);
    if (hits == null) {
      throw const RelayWebRefused(
        "the grid answered with something that isn't a search result",
        retryable: true,
      );
    }
    return hits;
  }

  @override
  Future<WebPage> read({
    required String baseUrl,
    required String apiKey,
    required String url,
  }) async {
    final decoded = await _post(
      Uri.parse('$baseUrl$kRelayWebContentsPath'),
      apiKey,
      {
        'urls': [url],
      },
      action: 'read a page',
    );
    final page = webPageFromJson(decoded);
    if (page == null) {
      throw const RelayWebRefused(
        "the grid answered with something that isn't a page",
        retryable: true,
      );
    }
    return page;
  }

  Future<Object?> _post(
    Uri url,
    String apiKey,
    Map<String, Object?> body, {
    required String action,
  }) async {
    final client = HttpClient()..connectionTimeout = kRelayWebDeadline;
    try {
      return await _send(
        client,
        url,
        apiKey,
        body,
        action: action,
      ).timeout(kRelayWebDeadline);
    } on RelayWebRefused {
      rethrow;
    } on Object catch (error) {
      throw RelayWebRefused("couldn't reach the grid: $error", retryable: true);
    } finally {
      client.close(force: true);
    }
  }

  Future<Object?> _send(
    HttpClient client,
    Uri url,
    String apiKey,
    Map<String, Object?> body, {
    required String action,
  }) async {
    final request = await client.postUrl(url);
    request.headers
      ..set(HttpHeaders.authorizationHeader, 'Bearer $apiKey')
      ..contentType = ContentType.json;
    request.write(jsonEncode(body));
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      decoded = null;
    }
    if (response.statusCode != HttpStatus.ok) {
      throw relayWebRefusal(response.statusCode, decoded, action: action);
    }
    return decoded;
  }
}
