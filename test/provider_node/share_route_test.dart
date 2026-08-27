import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/provider_node/logic/share_route.dart';

/// The page opens on whichever route it picks here, and the route it opens on
/// is the one most people will take. Opening on a route this machine cannot
/// take is the failure worth guarding: it puts a form in front of someone whose
/// first move has to be somewhere else entirely.

void main() {
  group('defaultShareRoute', () {
    test('leads with the local engine when this machine can run one', () {
      expect(
        defaultShareRoute(
          canRunLocal: true,
          serverFound: false,
          hasKeyProvider: false,
        ),
        ShareRoute.local,
        reason: 'the only route that costs nothing and sends nothing',
      );
    });

    test('still leads with local when the other two are also available', () {
      expect(
        defaultShareRoute(
          canRunLocal: true,
          serverFound: true,
          hasKeyProvider: true,
        ),
        ShareRoute.local,
        reason:
            'detection lands after the first frame, so a default that changed '
            'once Ollama was found would move the page under the reader',
      );
    });

    test('offers a server already running here when local is impossible', () {
      expect(
        defaultShareRoute(
          canRunLocal: false,
          serverFound: true,
          hasKeyProvider: true,
        ),
        ShareRoute.server,
        reason: 'one press from shared, against a key that has to be found',
      );
    });

    test('falls to a key when there is no engine and no server', () {
      expect(
        defaultShareRoute(
          canRunLocal: false,
          serverFound: false,
          hasKeyProvider: true,
        ),
        ShareRoute.key,
      );
    });

    test('never opens on a route this machine cannot take', () {
      for (final serverFound in [true, false]) {
        for (final hasKey in [true, false]) {
          expect(
            defaultShareRoute(
              canRunLocal: false,
              serverFound: serverFound,
              hasKeyProvider: hasKey,
            ),
            isNot(ShareRoute.local),
            reason:
                'no built-in engine here, so the local form has nothing to '
                'run — found=$serverFound key=$hasKey',
          );
        }
      }
    });

    test('lands on the endpoint form when nothing at all was detected', () {
      expect(
        defaultShareRoute(
          canRunLocal: false,
          serverFound: false,
          hasKeyProvider: false,
        ),
        ShareRoute.server,
        reason:
            'it takes a typed address, so it is the one route that is always '
            'available — a page has to open on something',
      );
    });
  });
}
