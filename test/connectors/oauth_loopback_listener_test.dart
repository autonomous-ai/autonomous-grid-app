import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/connectors/logic/oauth_loopback_listener.dart';

/// Drives the listener the way a browser would: a plain GET at its callback.
Future<HttpClientResponse> hit(String url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    return await request.close();
  } finally {
    client.close(force: true);
  }
}

void main() {
  group('binding', () {
    test(
      'takes a free port from the OS and reports it in the redirect',
      () async {
        final listener = await OAuthLoopbackListener.bind();
        addTearDown(listener.close);

        expect(listener.port, greaterThan(0));
        expect(
          listener.redirectUri,
          'http://127.0.0.1:${listener.port}/callback',
        );
      },
    );

    test('two listeners never collide', () async {
      // This test used to assert the port was *never* fixed, on the reasoning
      // that a hardcoded one would collide. That reasoning held and the
      // conclusion was still wrong: an unpredictable port changes the
      // `redirect_uri`, and a changed redirect URI is one the authorization
      // server never registered. The port is stable now, and collisions are
      // handled by having several to choose from — see the "a stable port"
      // group.
      final a = await OAuthLoopbackListener.bind();
      final b = await OAuthLoopbackListener.bind();
      addTearDown(a.close);
      addTearDown(b.close);

      expect(a.port, isNot(b.port));
    });

    test('listens on loopback only, not on the local network', () async {
      // Binding anyIPv4 would put the callback within reach of every machine
      // on the same Wi-Fi.
      final listener = await OAuthLoopbackListener.bind();
      addTearDown(listener.close);

      expect(listener.redirectUri, startsWith('http://127.0.0.1:'));
    });
  });

  group('the three ways a round trip ends', () {
    test('code and state come back as a success', () async {
      final listener = await OAuthLoopbackListener.bind();
      final pending = listener.waitForCallback();

      await hit('${listener.redirectUri}?code=gw-code&state=gw-state');
      final result = await pending;

      expect(result, isA<LoopbackSuccess>());
      final success = result as LoopbackSuccess;
      expect(success.code, 'gw-code');
      expect(success.state, 'gw-state');
    });

    test('access_denied reads as a cancel, not as a failure', () async {
      final listener = await OAuthLoopbackListener.bind();
      final pending = listener.waitForCallback();

      await hit('${listener.redirectUri}?error=access_denied&state=gw-state');
      final result = await pending;

      expect(result, isA<LoopbackDenied>());
      // The row goes quiet on this one. Treating it like a network error would
      // teach the user that changing their mind broke something.
      expect((result as LoopbackDenied).isCancel, isTrue);
    });

    test(
      'any other error is a real failure and carries its description',
      () async {
        final listener = await OAuthLoopbackListener.bind();
        final pending = listener.waitForCallback();

        await hit(
          '${listener.redirectUri}?error=invalid_scope'
          '&error_description=Scope%20not%20allowed&state=s',
        );
        final result = await pending;

        final denied = result as LoopbackDenied;
        expect(denied.isCancel, isFalse);
        expect(denied.error, 'invalid_scope');
        expect(denied.description, 'Scope not allowed');
      },
    );

    test('nothing arriving times out instead of hanging forever', () async {
      // The browser is outside this process: the user can close the tab, stall
      // at a login wall, or finish on another machine. Waiting forever would
      // leave a button spinning with no way back.
      final listener = await OAuthLoopbackListener.bind();

      final result = await listener.waitForCallback(
        timeout: const Duration(milliseconds: 200),
      );
      expect(result, isA<LoopbackTimeout>());
    });
  });

  group('noise on the port', () {
    test(
      'a request that is not a callback is answered but not acted on',
      () async {
        // Browsers probe /favicon.ico. Closing on the first stray request would
        // abandon a user who has not finished consenting yet.
        final listener = await OAuthLoopbackListener.bind();
        final pending = listener.waitForCallback(
          timeout: const Duration(seconds: 5),
        );

        final probe = await hit(
          'http://127.0.0.1:${listener.port}/favicon.ico',
        );
        expect(probe.statusCode, 200);

        // Still listening: the real callback lands afterwards and wins.
        await hit('${listener.redirectUri}?code=late&state=s');
        expect(await pending, isA<LoopbackSuccess>());
      },
    );

    test('a code with no state is not treated as a callback', () async {
      // Both handles are needed to finalize, so half of one is noise.
      final listener = await OAuthLoopbackListener.bind();
      final pending = listener.waitForCallback(
        timeout: const Duration(milliseconds: 400),
      );

      await hit('${listener.redirectUri}?code=orphan');
      expect(await pending, isA<LoopbackTimeout>());
    });
  });

  group('a stable port', () {
    test('binds one of the preferred ports', () async {
      final listener = await OAuthLoopbackListener.bind();
      addTearDown(listener.close);

      // The port has to be predictable across runs, because it is baked into the
      // `redirect_uri` a client is registered with. An OS-assigned one changes
      // every time, and reconnecting an existing registration then fails at the
      // authorize step with `invalid_redirect_uri` — measured against Achriom on
      // 2026-07-30, after a disconnect and reconnect.
      expect(OAuthLoopbackListener.preferredPorts, contains(listener.port));
    });

    test('two listeners at once take different preferred ports', () async {
      // A second copy of the app, or a stale listener, must not block a sign-in.
      final first = await OAuthLoopbackListener.bind();
      addTearDown(first.close);
      final second = await OAuthLoopbackListener.bind();
      addTearDown(second.close);

      expect(first.port, isNot(second.port));
      expect(OAuthLoopbackListener.preferredPorts, contains(second.port));
    });

    test('the redirect URI uses the literal loopback address', () async {
      final listener = await OAuthLoopbackListener.bind();
      addTearDown(listener.close);

      // Not `localhost`: it can resolve to IPv6 and miss a listener bound to
      // IPv4 (RFC 8252 §7.3).
      expect(
        listener.redirectUri,
        'http://127.0.0.1:${listener.port}/callback',
      );
    });
  });

  group('lifetime', () {
    test('the port is released once the callback is handled', () async {
      final listener = await OAuthLoopbackListener.bind();
      final port = listener.port;
      final pending = listener.waitForCallback();

      await hit('${listener.redirectUri}?code=c&state=s');
      await pending;

      // Nothing should still be holding the port: rebinding it proves the
      // listener isn't left running between links.
      final rebound = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
      );
      addTearDown(rebound.close);
      expect(rebound.port, port);
    });

    test('closing twice is safe — cancel and finish both end here', () async {
      final listener = await OAuthLoopbackListener.bind();
      await listener.close();
      await listener.close();
    });
  });
}
