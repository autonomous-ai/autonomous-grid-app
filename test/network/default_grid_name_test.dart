import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/default_grid_name.dart';

void main() {
  test('capitalizes the email local part', () {
    expect(defaultGridName('huy@gmail.com'), 'Huy Grid');
  });

  test('takes only the first name from a dotted local part', () {
    expect(defaultGridName('john.doe@example.com'), 'John Grid');
  });

  test('normalizes mixed case', () {
    expect(defaultGridName('HUY@gmail.com'), 'Huy Grid');
  });

  test('handles other local-part separators', () {
    expect(defaultGridName('jane_smith@x.io'), 'Jane Grid');
    expect(defaultGridName('amy+promo@x.io'), 'Amy Grid');
  });

  test('falls back to "My Grid" when there is no usable email', () {
    expect(defaultGridName(null), 'My Grid');
    expect(defaultGridName(''), 'My Grid');
    expect(defaultGridName('@gmail.com'), 'My Grid');
  });
}
