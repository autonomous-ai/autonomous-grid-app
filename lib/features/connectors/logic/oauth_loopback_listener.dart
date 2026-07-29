import 'dart:async';
import 'dart:io';

/// What came back from the browser at the end of an OAuth round trip.
///
/// Three shapes, and only one of them is a failure — the distinction the whole
/// flow turns on, because treating a cancel like an error teaches the user that
/// changing their mind broke something.
sealed class LoopbackResult {
  const LoopbackResult();
}

/// The gateway handed back its session handles. Neither is a provider
/// credential; [state] still has to be accepted by the gateway before this
/// means anything.
class LoopbackSuccess extends LoopbackResult {
  const LoopbackSuccess({required this.code, required this.state});

  final String code;
  final String state;
}

/// The provider said no — usually because the user clicked Deny.
///
/// [isCancel] separates "the user meant this" from a real refusal, so the row
/// can go quiet instead of turning red.
class LoopbackDenied extends LoopbackResult {
  const LoopbackDenied({required this.error, this.description = ''});

  final String error;
  final String description;

  bool get isCancel => error == 'access_denied';
}

/// Nothing arrived before the deadline.
///
/// The ordinary cause isn't a bug: the browser is outside this process, and a
/// user can close the tab, get stuck at a login wall, or finish on a different
/// machine. So this is a normal ending, not an exception.
class LoopbackTimeout extends LoopbackResult {
  const LoopbackTimeout();
}

/// A one-shot HTTP server on `127.0.0.1` that catches a single OAuth callback.
///
/// This is the desktop counterpart of the web's `/connector/callback` page, and
/// it exists instead of a `grid://` custom scheme for four reasons, each of
/// which was a real cost of the alternative: no `Info.plist` entry or
/// `app_links` dependency; no cold-start race where the URI is delivered before
/// any widget subscribes; no other app on the machine able to claim the scheme;
/// and it's what RFC 8252 §7.3 recommends for native apps — the same thing
/// Claude Code does.
///
/// The port is whatever the OS hands out ([bind] asks for `0`), and it's known
/// before the gateway is called, so the `redirect_uri` is always exact. A fixed
/// port would collide with whatever else the user is running and would let
/// another process sit on it waiting to intercept.
///
/// The listener lives only while one link is pending, and stops at the first
/// request it can read.
class OAuthLoopbackListener {
  OAuthLoopbackListener._(this._server);

  final HttpServer _server;

  int get port => _server.port;

  /// The URI to hand the gateway as `redirect_uri`.
  String get redirectUri => 'http://127.0.0.1:$port/callback';

  /// Bind a fresh listener on a free loopback port.
  ///
  /// Loopback-only on purpose: binding to `anyIPv4` would put the callback on
  /// the local network, where a machine on the same Wi-Fi could reach it.
  static Future<OAuthLoopbackListener> bind() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return OAuthLoopbackListener._(server);
  }

  /// Wait for the browser, then stop listening.
  ///
  /// Always completes: a [timeout] with nothing arriving yields
  /// [LoopbackTimeout] rather than hanging a button forever. The default is
  /// deliberately shorter than the gateway's ~10 minute session TTL, so the app
  /// gives up while the server still considers the state live — if the user
  /// finishes late, the backend still records it and the next poll catches up.
  Future<LoopbackResult> waitForCallback({
    Duration timeout = const Duration(minutes: 5),
  }) async {
    final completer = Completer<LoopbackResult>();
    late final StreamSubscription<HttpRequest> subscription;

    final timer = Timer(timeout, () {
      if (!completer.isCompleted) completer.complete(const LoopbackTimeout());
    });

    subscription = _server.listen(
      (request) async {
        final result = _read(request.uri);
        await _respond(request, result);
        // Anything that isn't a callback (a favicon probe, a stray scan) gets
        // its page and is otherwise ignored — closing on the first byte of
        // noise would abandon a user who hasn't finished yet.
        if (result != null && !completer.isCompleted) {
          completer.complete(result);
        }
      },
      onError: (Object _) {
        if (!completer.isCompleted) completer.complete(const LoopbackTimeout());
      },
    );

    try {
      return await completer.future;
    } finally {
      timer.cancel();
      await subscription.cancel();
      await close();
    }
  }

  /// Stop listening. Safe to call more than once — cancelling a pending link
  /// and finishing one both end here.
  Future<void> close() async {
    try {
      await _server.close(force: true);
    } on Object {
      // Already closed; nothing to report.
    }
  }

  /// Read one callback URI, or null when this request isn't one.
  static LoopbackResult? _read(Uri uri) {
    final params = uri.queryParameters;
    final error = params['error'];
    if (error != null && error.isNotEmpty) {
      return LoopbackDenied(
        error: error,
        description: params['error_description'] ?? '',
      );
    }
    final code = params['code'];
    final state = params['state'];
    if (code != null && code.isNotEmpty && state != null && state.isNotEmpty) {
      return LoopbackSuccess(code: code, state: state);
    }
    return null;
  }

  static Future<void> _respond(
    HttpRequest request,
    LoopbackResult? result,
  ) async {
    final line = switch (result) {
      LoopbackSuccess() => 'You can go back to Grid now.',
      LoopbackDenied(isCancel: true) =>
        'Sign-in cancelled. You can close this '
            'tab and go back to Grid.',
      LoopbackDenied() =>
        "That didn't work. You can close this tab and try "
            'again in Grid.',
      _ => 'Waiting for Grid…',
    };
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..write(_page(line));
    await request.response.close();
  }

  /// The page the browser is left on.
  ///
  /// Self-contained by necessity — this is served from a socket that closes
  /// moments later, so a stylesheet or font request would land on nothing. It
  /// follows the system colour scheme so it doesn't flash white at a user in
  /// dark mode.
  static String _page(String line) =>
      '''
<!doctype html>
<html><head><meta charset="utf-8"><title>Grid</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; height: 100vh; display: flex; align-items: center;
         justify-content: center; background: #fff; color: #1a1a1a;
         font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  @media (prefers-color-scheme: dark) {
    body { background: #0a0a0a; color: #ededed; }
  }
</style></head>
<body><p>$line</p></body></html>
''';
}
