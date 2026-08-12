import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The tokens-per-second a `chat/completions` reply reports **of itself**, or
/// null when the body doesn't carry enough to say.
///
/// Pure, so `test/provider_node/` can pin it: this is the one place a warm-up
/// reply is turned into a number, and a wrong reading here is a benchmark that
/// lies quietly on the card.
///
/// Only the server's own measured decode rate counts. llama.cpp's server returns
/// a `timings` block with `predicted_per_second` — the rate it actually
/// generated at, prompt evaluation excluded — which is the figure the card
/// wants; its `predicted_n / predicted_ms` are the same number the long way,
/// kept for a build that drops the convenience field.
///
/// It deliberately does **not** fall back to timing the round trip over
/// `usage.completion_tokens`. That fallback was written when the warm-up went to
/// the local engine; it now goes through the relay, so a wall clock counts the
/// TLS handshake, the hop and the prompt eval, and a machine generating 250
/// tok/s would report 34 — printed with no qualifier beside other nodes'
/// properly measured rates. A blank is the honest answer when nobody measured.
///
/// TODO(BE): an OpenAI-shaped relay may not forward llama.cpp's `timings` at
/// all, in which case this returns null for every grid warm-up and the card
/// stays blank until the relay's own overview reports the node — which the
/// warm-up is what triggers. If the relay can pass `timings` through, the card
/// fills a poll sooner.
double? parseTokensPerSecond(Map<String, dynamic> body) {
  final timings = body['timings'];
  if (timings is! Map) return null;
  final perSecond = timings['predicted_per_second'];
  if (perSecond is num && perSecond > 0) return perSecond.toDouble();
  final n = timings['predicted_n'];
  final ms = timings['predicted_ms'];
  if (n is num && ms is num && n > 0 && ms > 0) return n / (ms / 1000.0);
  return null;
}

/// Sends one tiny message to a model and measures how fast it answers.
///
/// The seam behind [throughputProbeProvider], so the local-throughput watcher
/// can be tested with a fake instead of a live grid.
abstract interface class ThroughputProbe {
  /// tok/s for [model] at [endpoint] (a full `chat/completions` URL), or null
  /// when it couldn't be measured. Never throws.
  ///
  /// [apiKey] is the grid's bearer token — the warm-up goes to the **grid URL**,
  /// not the local engine, so the relay routes it to whichever machine serves
  /// [model] and the *grid* is the one that times the answer. Empty for a
  /// keyless endpoint.
  Future<double?> measure({
    required String endpoint,
    required String apiKey,
    required String model,
  });
}

/// Real probe over `dart:io`. Posts "hi" to [endpoint] with streaming off, so
/// the whole body — timings and usage included — arrives as one JSON object to
/// read the rate out of.
class HttpThroughputProbe implements ThroughputProbe {
  const HttpThroughputProbe();

  /// A short generation: enough tokens for the decode rate to settle, not so
  /// many that a warm-up ties up the engine a user is about to chat with.
  static const _maxTokens = 48;

  /// The whole exchange's budget — headers *and* body. It wraps the entire
  /// call rather than `close()` alone: a relay that answers 200 and then stalls
  /// mid-body leaves the read hanging forever, and with it the future, the
  /// `finally` that closes the connection and the provider awaiting the number.
  static const _budget = Duration(seconds: 30);

  @override
  Future<double?> measure({
    required String endpoint,
    required String apiKey,
    required String model,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      return await _ask(client, endpoint, apiKey, model).timeout(_budget);
    } on Object {
      // A warm-up may never take the app down; a machine that can't be timed
      // simply keeps the blank the card already shows. A timeout lands here too,
      // and `finally` closes the socket the stalled read was waiting on.
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// One warm-up round trip, with no timeout of its own — [measure] owns that.
  Future<double?> _ask(
    HttpClient client,
    String endpoint,
    String apiKey,
    String model,
  ) async {
    final request = await client.postUrl(Uri.parse(endpoint));
    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    if (apiKey.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
    }
    request.add(
      utf8.encode(
        jsonEncode({
          'model': model,
          'messages': [
            {'role': 'user', 'content': 'hi'},
          ],
          'stream': false,
          'max_tokens': _maxTokens,
        }),
      ),
    );
    final response = await request.close();
    if (response.statusCode != 200) return null;
    final bodyText = await response.transform(utf8.decoder).join();
    final decoded = jsonDecode(bodyText);
    if (decoded is! Map) return null;
    return parseTokensPerSecond(Map<String, dynamic>.from(decoded));
  }
}

/// Overridable so the local-throughput watcher runs against a fake in tests.
final throughputProbeProvider = Provider<ThroughputProbe>(
  (ref) => const HttpThroughputProbe(),
);
