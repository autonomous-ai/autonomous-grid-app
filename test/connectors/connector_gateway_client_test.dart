import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/connectors/logic/connector_link_status.dart';
import 'package:grid_app/infrastructure/api/connector_gateway_client.dart';

void main() {
  group('parseAuthorizeGrant', () {
    test('reads the URL the browser should be sent to', () {
      final grant = parseAuthorizeGrant('''
{"status": 1, "data": {"authorize_url": "https://accounts.google.com/o/oauth2/v2/auth?x=1",
 "auth_type": "oauth"}}
''')!;
      expect(grant.authorizeUrl, startsWith('https://accounts.google.com/'));
      expect(grant.authType, 'oauth');
    });

    test('no usable URL reads as null, so no browser opens at nothing', () {
      expect(parseAuthorizeGrant('{"status": 1, "data": {}}'), isNull);
      expect(
        parseAuthorizeGrant('{"status": 1, "data": {"authorize_url": ""}}'),
        isNull,
      );
      expect(parseAuthorizeGrant('not json'), isNull);
      expect(parseAuthorizeGrant('{"status": 1}'), isNull);
    });
  });

  group('parseEnvelopeError', () {
    test('a 200 that says status != 1 is still a failure', () {
      // The gateway reports business failures inside the envelope. Trusting the
      // HTTP code alone would report "signed in" for a body saying otherwise.
      expect(
        parseEnvelopeError(
          '{"status": 0, "error_message": "state not found or expired"}',
        ),
        'state not found or expired',
      );
    });

    test('prefers error_message over the generic message', () {
      expect(
        parseEnvelopeError(
          '{"status": 0, "message": "Bad Request", '
          '"error_message": "connector already linked"}',
        ),
        'connector already linked',
      );
    });

    test('finds the message nested under data', () {
      expect(
        parseEnvelopeError(
          '{"status": 0, "data": {"error_message": "device not registered"}}',
        ),
        'device not registered',
      );
    });

    test('a failure with no text still says something actionable', () {
      expect(parseEnvelopeError('{"status": 0}'), isNotNull);
    });

    test('a healthy envelope claims nothing', () {
      expect(parseEnvelopeError('{"status": 1, "data": {}}'), isNull);
    });

    test('a body that is not JSON is not an error claim', () {
      // The caller still has the HTTP status to fall back on; inventing an
      // error here would mask it.
      expect(parseEnvelopeError('<html>502</html>'), isNull);
      expect(parseEnvelopeError(''), isNull);
    });
  });

  group('parseDeviceConnectors', () {
    const body = '''
{"status": 1, "data": {"connectors": [
  {"code": "gmail", "status": "connected"},
  {"code": "slack", "status": "connecting"},
  {"code": "notion", "status": "connect_failed", "error_message": "scope refused"},
  {"code": "drive", "status": "not_installed"},
  {"status": "connected"},
  "not even an object"
]}}
''';

    test('reads each row into a state the screen can render', () {
      final connectors = parseDeviceConnectors(body)!;
      expect(connectors.map((c) => c.code), [
        'gmail',
        'slack',
        'notion',
        'drive',
      ]);
      expect(connectors[0].status, ConnectorLinkStatus.connected);
      expect(connectors[1].status, ConnectorLinkStatus.connecting);
      expect(connectors[2].status, ConnectorLinkStatus.connectFailed);
      expect(connectors[3].status, ConnectorLinkStatus.notInstalled);
    });

    test('carries the failure reason so the row can explain itself', () {
      final notion = parseDeviceConnectors(
        body,
      )!.firstWhere((c) => c.code == 'notion');
      expect(notion.errorMessage, 'scope refused');
    });

    test('a row with no code is dropped and the rest still show', () {
      expect(parseDeviceConnectors(body)!.length, 4);
    });

    test('nothing linked is [] but an unreadable body is null', () {
      // Two different things to a screen: one is "you have no connectors", the
      // other is "we could not find out".
      expect(
        parseDeviceConnectors('{"status": 1, "data": {"connectors": []}}'),
        isEmpty,
      );
      expect(parseDeviceConnectors('not json'), isNull);
      expect(parseDeviceConnectors('{"status": 1}'), isNull);
    });

    test('accepts a bare list under data as well as the wrapped shape', () {
      // The exact envelope for this endpoint is unconfirmed (spec §11) — read
      // both rather than blanking the screen on the shape we guessed wrong.
      final connectors = parseDeviceConnectors(
        '{"status": 1, "data": [{"code": "gmail", "status": "connected"}]}',
      )!;
      expect(connectors.single.code, 'gmail');
    });
  });

  group('ConnectorGatewayClient', () {
    test('builds endpoints with or without a trailing slash', () {
      expect(
        ConnectorGatewayClient.endpoint(
          'https://api.example.com',
          'v1/connectors/authorize',
        ).toString(),
        'https://api.example.com/v1/connectors/authorize',
      );
      expect(
        ConnectorGatewayClient.endpoint(
          'https://api.example.com/',
          'v1/connectors/authorize',
        ).toString(),
        'https://api.example.com/v1/connectors/authorize',
      );
    });

    test('signed out never reaches the network', () async {
      // A connector links to an account, so there is nothing to ask for without
      // a session — and asking anyway would spend a timeout to learn it.
      const client = ConnectorGatewayClient(
        apiUrl: 'https://api.example.com',
        sessionToken: null,
      );
      final (grant, error) = await client.authorize(
        connector: 'gmail',
        deviceId: 'device-1',
        deviceType: '15',
        redirectUri: 'http://127.0.0.1:1234/callback',
      );
      expect(grant, isNull);
      expect(error?.message, 'Not signed in.');
    });
  });
}
