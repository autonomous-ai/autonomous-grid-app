import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A feedback submission failed. [message] is the plain-language line the dialog
/// shows; [statusCode] and [body] carry the raw detail for the Debug tab, so an
/// opaque gateway error isn't just "Error 502" with nothing to go on.
///
/// Mirrors `ManagedNetworkError` on purpose — the control plane's two write APIs
/// should fail the same way.
class FeedbackError {
  const FeedbackError(this.message, {this.statusCode, this.body});

  final String message;

  /// HTTP status when the server answered; null for transport failures
  /// (timeout, unreachable host) where there was no response.
  final int? statusCode;

  /// Raw response body when there was one, for the Debug tab.
  final String? body;

  /// The Debug-tab line: the friendly message plus any raw server body
  /// (clipped), so the log shows what actually came back.
  String get debugDetail {
    final raw = body?.trim();
    if (raw == null || raw.isEmpty || raw == message) return message;
    final clipped = raw.length > 1000 ? '${raw.substring(0, 1000)}…' : raw;
    return '$message\n$clipped';
  }
}

/// Sends user feedback to the control plane.
///
/// An interface rather than a bare function so a caller can be exercised against
/// a fake instead of a live server, the same seam `RelayApiClient` uses.
abstract interface class FeedbackClient {
  /// `POST {apiUrl}/v1/feedback`, authenticated with the GridSession bearer.
  /// Returns null on success, a [FeedbackError] otherwise — it never throws.
  ///
  /// With [logsZip] the body is `multipart/form-data`: a `payload` part (the
  /// JSON) and a `logs` part (the zip). Without it, a plain `application/json`
  /// body. The user's switch decides which — logs ride along only when they
  /// opted in, so the transport is chosen by consent, not by convenience.
  Future<FeedbackError?> send({
    required String apiUrl,
    required String sessionToken,
    required Map<String, dynamic> payload,
    List<int>? logsZip,
  });
}

/// Real [FeedbackClient] over `dart:io` [HttpClient], matching the rest of the
/// app's HTTP (no `package:http`).
///
/// Sends JSON alone, or `multipart/form-data` (a `payload` part + a `logs` zip
/// part) when the user attached the diagnostic logs — see [send].
///
/// TODO(BE): the route is not live yet. Until the control plane serves
/// `POST /v1/feedback` every submission comes back 404, which the app reports
/// honestly ("Feedback isn't switched on yet") and keeps a local copy of via
/// `FeedbackOutbox` — nothing the user typed is lost, but nothing reaches us
/// either. Confirm the path, the field names in [feedbackPayload], and the
/// multipart part names (`payload`, `logs`) against the server — the full
/// contract is in `.claude/feedback-api-contract.md`.
class HttpFeedbackClient implements FeedbackClient {
  const HttpFeedbackClient();

  /// The endpoint path appended to the control-plane base URL.
  static const String _path = 'v1/feedback';

  /// The full URL, exposed so the Debug tab's line names the exact call.
  static Uri endpoint(String apiUrl) =>
      Uri.parse('${apiUrl.replaceFirst(RegExp(r'/+$'), '')}/$_path');

  /// Multipart boundary marker. A fixed, unusual token — the parts are a JSON
  /// blob and a zip, neither of which contains this string, so a random suffix
  /// would buy nothing (and `Math.random` is unavailable to the workflow layer
  /// anyway). Long enough not to collide by accident.
  static const _boundary = 'GridFeedbackBoundary7c3f9a1e2b6d4085';

  @override
  Future<FeedbackError?> send({
    required String apiUrl,
    required String sessionToken,
    required Map<String, dynamic> payload,
    List<int>? logsZip,
  }) async {
    // A zip attachment can be megabytes; give the upload room the JSON path
    // never needs.
    final withLogs = logsZip != null && logsZip.isNotEmpty;
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.postUrl(endpoint(apiUrl));
      request.headers.set(
        HttpHeaders.authorizationHeader,
        'Bearer $sessionToken',
      );
      final requestBody = withLogs
          ? _multipartBody(payload, logsZip)
          : utf8.encode(jsonEncode(payload));
      request.headers.set(
        HttpHeaders.contentTypeHeader,
        withLogs
            ? 'multipart/form-data; boundary=$_boundary'
            : 'application/json',
      );
      // Set the length so the body isn't sent chunked — a plain gateway in front
      // of the control plane may reject a chunked upload, and a megabyte-sized
      // zip is exactly where that would bite.
      request.contentLength = requestBody.length;
      request.add(requestBody);

      final response = await request.close().timeout(
        Duration(seconds: withLogs ? 60 : 20),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode >= 200 && response.statusCode < 300) return null;
      return FeedbackError(
        _messageFor(response.statusCode),
        statusCode: response.statusCode,
        body: body,
      );
    } on TimeoutException {
      return const FeedbackError("The server didn't respond in time.");
    } on SocketException catch (e) {
      return FeedbackError("Couldn't reach Grid: ${e.message}");
    } on Object catch (e) {
      return FeedbackError("Couldn't send your feedback: $e");
    } finally {
      client.close(force: true);
    }
  }

  /// Encodes the two-part `multipart/form-data` body by hand — the app has no
  /// `package:http`, so there is no `MultipartRequest` to lean on. Order is
  /// deliberate: the small JSON `payload` first, so a server streaming the parts
  /// has the message and its metadata before the megabytes of `logs`.
  List<int> _multipartBody(Map<String, dynamic> payload, List<int> zip) {
    final head = utf8.encode(
      '--$_boundary\r\n'
      'Content-Disposition: form-data; name="payload"\r\n'
      'Content-Type: application/json\r\n\r\n'
      '${jsonEncode(payload)}\r\n'
      '--$_boundary\r\n'
      'Content-Disposition: form-data; name="logs"; '
      'filename="grid-logs.zip"\r\n'
      'Content-Type: application/zip\r\n\r\n',
    );
    final tail = utf8.encode('\r\n--$_boundary--\r\n');
    return [...head, ...zip, ...tail];
  }

  /// A status turned into something the user can act on. Every branch says what
  /// *they* can do next; the raw status travels to the Debug tab instead of
  /// into this sentence.
  static String _messageFor(int status) => switch (status) {
    401 || 403 =>
      'Your session has expired. Sign out, sign back in and try '
          'again.',
    404 => "Feedback isn't switched on yet on this server.",
    413 => "That's more than the server accepts. Try a shorter message.",
    429 => "That's a lot of feedback at once. Try again in a few minutes.",
    >= 500 => 'The server had a problem. Try again in a moment.',
    _ => "Couldn't send your feedback (error $status).",
  };
}

/// The feedback-send seam. A real HTTP client by default.
final feedbackClientProvider = Provider<FeedbackClient>(
  (ref) => const HttpFeedbackClient(),
);
