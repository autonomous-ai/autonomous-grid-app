import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/api/models/media_event.dart';

/// Streams a media generation request (image / video) to a relay media endpoint
/// and yields its Server-Sent [MediaEvent]s — `progress` updates followed by a
/// `result`. The seam behind [mediaTransportProvider] so the controller can be
/// tested with a fake stream instead of a live relay.
abstract interface class MediaTransport {
  Stream<MediaEvent> stream({
    required String url,
    required String apiKey,
    required Map<String, dynamic> payload,
  });
}

/// Real [MediaTransport] over `dart:io` [HttpClient]. Emits a terminal
/// [MediaError] instead of throwing so the controller has one thing to handle.
/// An inactivity timeout (not a total-time cap) guards against a dead stream
/// while still allowing the minutes a generation legitimately takes.
class HttpMediaTransport implements MediaTransport {
  const HttpMediaTransport();

  static const _idleTimeout = Duration(minutes: 5);

  @override
  Stream<MediaEvent> stream({
    required String url,
    required String apiKey,
    required Map<String, dynamic> payload,
  }) async* {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.postUrl(Uri.parse(url));
      request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
      request.headers.set(HttpHeaders.acceptHeader, 'text/event-stream');
      if (apiKey.isNotEmpty) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      }
      request.add(utf8.encode(jsonEncode(payload)));

      final response = await request.close();
      if (response.statusCode != 200) {
        final body = await response.transform(utf8.decoder).join();
        yield MediaError(_briefError(response.statusCode, body));
        return;
      }

      final lines = response
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .timeout(_idleTimeout);
      await for (final line in lines) {
        if (!line.startsWith('data:')) continue;
        final event = MediaEvent.fromSseData(line.substring(5));
        if (event != null) yield event;
      }
    } on TimeoutException {
      yield const MediaError('The generation stalled — no response in time.');
    } on SocketException catch (e) {
      yield MediaError("Couldn't reach the grid: ${e.message}");
    } on Object catch (e) {
      yield MediaError("Couldn't generate media: $e");
    } finally {
      client.close(force: true);
    }
  }

  static String _briefError(int status, String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final detail = decoded['detail'] ?? decoded['error'];
        if (detail is String && detail.trim().isNotEmpty) return detail.trim();
        if (detail != null) return '$detail';
      }
    } on Object {
      // Non-JSON body — fall through.
    }
    final trimmed = body.trim();
    if (trimmed.isEmpty) return 'The grid returned an error (HTTP $status).';
    return trimmed.length > 200 ? '${trimmed.substring(0, 200)}…' : trimmed;
  }
}

/// The media transport used by the Playground. Override in tests with a fake.
final mediaTransportProvider =
    Provider<MediaTransport>((ref) => const HttpMediaTransport());
