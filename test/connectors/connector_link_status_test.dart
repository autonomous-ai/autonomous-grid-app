import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/connectors/logic/connector_link_status.dart';

void main() {
  group('parseConnectorLinkStatus', () {
    test('reads every state the gateway sends', () {
      expect(
        parseConnectorLinkStatus('not_installed'),
        ConnectorLinkStatus.notInstalled,
      );
      expect(parseConnectorLinkStatus('connect'), ConnectorLinkStatus.connect);
      expect(
        parseConnectorLinkStatus('connecting'),
        ConnectorLinkStatus.connecting,
      );
      expect(
        parseConnectorLinkStatus('connected'),
        ConnectorLinkStatus.connected,
      );
      expect(
        parseConnectorLinkStatus('connect_failed'),
        ConnectorLinkStatus.connectFailed,
      );
    });

    test('a state we have never heard of never reads as connected', () {
      // The backend may grow states. Guessing "connected" would promise a tool
      // the agent has no way to call; "connect" at worst offers a button.
      expect(
        parseConnectorLinkStatus('needs_reauth'),
        ConnectorLinkStatus.connect,
      );
      expect(parseConnectorLinkStatus(42), ConnectorLinkStatus.notInstalled);
    });

    test('nothing at all reads as not installed', () {
      expect(parseConnectorLinkStatus(null), ConnectorLinkStatus.notInstalled);
      expect(parseConnectorLinkStatus(''), ConnectorLinkStatus.notInstalled);
    });
  });

  group('the two derived questions a row asks', () {
    test(
      'only connecting is still settling — that is what drives the poll',
      () {
        expect(ConnectorLinkStatus.connecting.isSettling, isTrue);
        for (final status in ConnectorLinkStatus.values) {
          if (status == ConnectorLinkStatus.connecting) continue;
          expect(status.isSettling, isFalse, reason: '$status');
        }
      },
    );

    test('connecting belongs in the Connected bucket, so rows do not jump', () {
      // It is on its way there. Moving it between buckets mid-flight would make
      // the list reorder under the user's cursor.
      expect(ConnectorLinkStatus.connecting.isLinked, isTrue);
      expect(ConnectorLinkStatus.connected.isLinked, isTrue);
      expect(ConnectorLinkStatus.connect.isLinked, isFalse);
      expect(ConnectorLinkStatus.connectFailed.isLinked, isFalse);
      expect(ConnectorLinkStatus.notInstalled.isLinked, isFalse);
    });
  });
}
