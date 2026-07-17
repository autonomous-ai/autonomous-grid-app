import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/auth/logic/device_login_parser.dart';

void main() {
  test('extracts url and code, keyed on shape not label wording', () {
    final parser = DeviceLoginParser();
    parser.feed('Open this URL to sign in with Google:');
    expect(parser.result, isNull, reason: 'incomplete until both seen');

    parser.feed('https://staging.example/grid/device-login?user_code=AB-12');
    parser.feed('Code: AB-12');

    expect(parser.result, isNotNull);
    expect(
      parser.result!.url,
      'https://staging.example/grid/device-login?user_code=AB-12',
    );
    expect(parser.result!.userCode, 'AB-12');
  });

  test('ignores noise lines', () {
    final parser = DeviceLoginParser();
    parser.feed('some banner');
    parser.feed('Logged in as x; fetched 1 token(s).');
    expect(parser.result, isNull);
  });
}
