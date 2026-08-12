import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The tokens-per-second a `chat/completions` reply reports, or null when the
/// body doesn't carry enough to say.
///
/// Pure, so `test/provider_node/` can pin it: this is the one place a warm-up
/// reply is turned into a number, and a wrong reading here is a benchmark that
/// lies quietly on the card.
///
/// Prefers the server's own measured decode rate. llama.cpp's server returns a
/// `timings` block with `predicted_per_second` — the rate it actually generated
/// at, prompt evaluation excluded — which is exactly the figure the card wants
/// and far better than anything timed from here, where the network and the
/// prompt eval are folded in. Its `predicted_n / predicted_ms` are the same
/// number the long way, kept as a fallback for a build that drops the
/// convenience field. Only when neither is there does it fall back to
/// [wall]-clock over `usage.completion_tokens`, which is rough — it counts the
/// round trip and the prompt — but a rough number beats a blank when the point
/// is "is this machine fast or slow".
double? parseTokensPerSecond(Map<String, dynamic> body, Duration wall) {
  final timings = body['timings'];
  if (timings is Map) {
    final perSecond = timings['predicted_per_second'];
    if (perSecond is num && perSecond > 0) return perSecond.toDouble();
    final n = timings['predicted_n'];
    final ms = timings['predicted_ms'];
    if (n is num && ms is num && n > 0 && ms > 0) {
      return n / (ms / 1000.0);
    }
  }
  final usage = body['usage'];
  final completion = usage is Map ? usage['completion_tokens'] : null;
  final seconds = wall.inMilliseconds / 1000.0;
  if (completion is num && completion > 0 && seconds > 0) {
    return completion / seconds;
  }
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

  @override
  Future<double?> measure({
    required String endpoint,
    required String apiKey,
    required String model,
  }) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final stopwatch = Stopwatch()..start();
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
      final response = await request.close().timeout(
        const Duration(seconds: 30),
      );
      if (response.statusCode != 200) return null;
      final bodyText = await response.transform(utf8.decoder).join();
      stopwatch.stop();
      final decoded = jsonDecode(bodyText);
      if (decoded is! Map) return null;
      return parseTokensPerSecond(
        Map<String, dynamic>.from(decoded),
        stopwatch.elapsed,
      );
    } on Object {
      // A warm-up may never take the app down; a machine that can't be timed
      // simply keeps the blank the card already shows.
      return null;
    } finally {
      client.close(force: true);
    }
  }
}

/// Overridable so the local-throughput watcher runs against a fake in tests.
final throughputProbeProvider = Provider<ThroughputProbe>(
  (ref) => const HttpThroughputProbe(),
);
