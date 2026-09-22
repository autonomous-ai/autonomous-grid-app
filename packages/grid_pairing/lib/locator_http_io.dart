/// The one `dart:io` caller the locator needs, shared by both apps.
///
/// Deliberately its own library rather than part of `grid_pairing.dart`: that
/// one is pure Dart so the phone can depend on it, and this file is the single
/// exception — `dart:io` is available on every platform either app runs on, but
/// it is still an import the codec itself must never grow.
///
/// It lives here rather than once per app because it would otherwise be the
/// same forty lines in two places, and the one that gets a timeout or a header
/// fixed is never the one that needed it.
library;

import 'dart:convert';
import 'dart:io';

import 'src/locator_client.dart';

/// How long any one locator call may take.
///
/// A phone on a bad connection is the normal case, and the caller has a screen
/// to put a failure on. Long enough for a slow handshake, short enough that
/// "your computer is asleep" does not take a minute to say.
const Duration kLocatorCallTimeout = Duration(seconds: 20);

/// Makes the locator's HTTP calls with one pooled [HttpClient].
///
/// Pooled because a computer republishing its address opens the same two
/// connections over and over, and because a client per call leaks sockets on
/// iOS in exactly the way that is hard to see.
class LocatorHttp {
  LocatorHttp({HttpClient? client, this.timeout = kLocatorCallTimeout})
    : _client = client ?? HttpClient();

  final HttpClient _client;

  /// How long one call may take before it is given up on.
  final Duration timeout;

  /// The transport to hand [LocatorClient].
  LocatorSend get send => _send;

  /// Lets the sockets go. Every owner of one of these has an `onDispose`.
  void close() => _client.close(force: true);

  Future<LocatorReply> _send(LocatorCall call) async {
    try {
      final request = await _client
          .openUrl(call.method, call.uri)
          .timeout(timeout);
      final idToken = call.idToken;
      if (idToken != null) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $idToken');
      }
      final body = call.body;
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(body));
      }
      final response = await request.close().timeout(timeout);
      final text = await response
          .transform(utf8.decoder)
          .join()
          .timeout(timeout);
      return (status: response.statusCode, body: text);
    } on Object {
      // Status 0 is this transport's word for "never reached the server", which
      // is what [LocatorOffline] is looking for. Throwing instead would make
      // every caller wrap this in a try that says the same thing.
      return (status: 0, body: '');
    }
  }
}
