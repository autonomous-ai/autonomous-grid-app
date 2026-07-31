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

/// The authorization server handed back a code.
///
/// [code] is single-use and worthless without the PKCE `code_verifier` this app
/// kept in memory. [state] must equal the one sent — on path A the app mints it,
/// so the app is also what verifies it (unlike the gateway path, where the BE
/// minted and validated `state`).
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
/// **Used by path A only** (the app as its own OAuth client, via dynamic client
/// registration). The gateway path needs nothing like this: it hands back a
/// `pickup_code` and the app polls, so no callback ever reaches this process
/// (D12). This file was deleted with that change and restored — unchanged apart
/// from these comments — when path A brought the need back.
///
/// It exists instead of a `grid://` custom scheme for four reasons, each of which
/// was a real cost of the alternative: no `Info.plist` entry or `app_links`
/// dependency; no cold-start race where the URI is delivered before any widget
/// subscribes; no other app on the machine able to claim the scheme; and it's
/// what RFC 8252 §7.3 recommends for native apps — the same thing Claude Code
/// does.
///
/// The port is whatever the OS hands out ([bind] asks for `0`), and it's known
/// before the authorization server is called, so the `redirect_uri` is always
/// exact. A fixed port would collide with whatever else the user is running and
/// would let another process sit on it waiting to intercept.
///
/// The listener lives only while one link is pending, and stops at the first
/// request it can read.
class OAuthLoopbackListener {
  OAuthLoopbackListener._(this._server);

  final HttpServer _server;

  int get port => _server.port;

  /// The URI to register and to send as `redirect_uri`.
  ///
  /// The same string must go into the registration, the authorize call, and the
  /// token exchange — byte for byte (RFC 6749 §4.1.3). `127.0.0.1` rather than
  /// `localhost` on purpose: RFC 8252 §7.3 prefers the literal address, since
  /// `localhost` can resolve to IPv6 and miss a listener bound to IPv4.
  String get redirectUri => 'http://127.0.0.1:$port/callback';

  /// Ports tried, in order, before giving up and letting the OS choose.
  ///
  /// **A stable port is the whole point.** An OS-assigned one changes every run,
  /// and a `redirect_uri` that changes is a `redirect_uri` the authorization
  /// server never registered: reconnecting an already-registered client fails
  /// with `invalid_redirect_uri`, which is exactly what Achriom returned on
  /// 2026-07-30 after a disconnect and reconnect.
  ///
  /// Several, because a single fixed port is a single point of failure — another
  /// app, or a second copy of this one, can be holding it. Any of these works as
  /// long as the *same* one is used at registration and at authorize time, and
  /// the reuse path re-registers when it can't match (see `DcrOAuthClient`).
  ///
  /// The numbers sit in the IANA dynamic range and are not assigned to anything.
  static const List<int> preferredPorts = [51789, 51790, 51791, 51792];

  /// Bind a listener, preferring a stable port.
  ///
  /// Falls back to an OS-assigned port when every preferred one is taken —
  /// better a sign-in that needs one extra registration than no sign-in at all.
  ///
  /// Loopback-only on purpose: binding to `anyIPv4` would put the callback on
  /// the local network, where a machine on the same Wi-Fi could reach it.
  static Future<OAuthLoopbackListener> bind() async {
    for (final port in preferredPorts) {
      try {
        final server = await HttpServer.bind(
          InternetAddress.loopbackIPv4,
          port,
        );
        return OAuthLoopbackListener._(server);
      } on SocketException {
        // In use by something else. Try the next.
      }
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return OAuthLoopbackListener._(server);
  }

  /// Wait for the browser, then stop listening.
  ///
  /// Always completes: a [timeout] with nothing arriving yields
  /// [LoopbackTimeout] rather than hanging a button forever. Five minutes is a
  /// login wall plus a consent screen with room to spare; longer and a forgotten
  /// tab keeps a socket open, shorter and a user reading the scope list loses
  /// their sign-in.
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
      LoopbackSuccess() => 'Signed in. You can close this tab.',
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
      // Only the success page tries to close itself. A cancel or a refusal is
      // something the user may want to read twice — closing the tab out from
      // under them would take the only explanation they were given.
      ..write(_page(line, closeSelf: result is LoopbackSuccess));
    await request.response.close();
  }

  /// The page the browser is left on.
  ///
  /// Self-contained by necessity — this is served from a socket that closes
  /// moments later, so a stylesheet or font request would land on nothing. It
  /// follows the system colour scheme so it doesn't flash white at a user in
  /// dark mode.
  ///
  /// [closeSelf] adds a best-effort attempt to shut the tab. **Expect it to
  /// fail**, and that is why the visible sentence still tells the user to close
  /// it themselves rather than promising anything. Browsers permit
  /// `window.close()` only for a browsing context a script opened, or one whose
  /// session history has a single entry (HTML §7.5.3); this tab was opened by
  /// the OS at the provider's authorize URL and then navigated through a consent
  /// screen, so neither usually holds. It costs one line and one refused call,
  /// and it does work on the providers that redirect straight through — the app
  /// being raised in front (`bringAppToFront`) is the part that always works.
  static String _page(String line, {bool closeSelf = false}) =>
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
<body><p>$line</p>${closeSelf ? _closeScript : ''}</body></html>
''';

  /// Deferred a beat rather than run inline: closing before the response has
  /// finished painting leaves a blank tab flashing shut, and if the close is
  /// refused — the common case — the delay is invisible anyway.
  static const String _closeScript =
      '<script>setTimeout(function(){try{window.close()}catch(e){}},350)</script>';
}
