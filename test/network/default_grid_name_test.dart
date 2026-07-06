import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/network/logic/default_grid_name.dart';

void main() {
  test('prefers the first name from the profile name, keeping diacritics', () {
    expect(defaultGridName(name: 'Đức Nguyễn', email: 'duc@x.io'), 'Đức AI Grid');
    expect(defaultGridName(name: 'Huy Pham'), 'Huy AI Grid');
  });

  test('title-cases a lower/upper-case profile first name', () {
    expect(defaultGridName(name: 'đức'), 'Đức AI Grid');
    expect(defaultGridName(name: 'JOHN doe'), 'John AI Grid');
  });

  test('falls back to the email when the profile name is blank', () {
    expect(defaultGridName(name: '   ', email: 'huy@gmail.com'), 'Huy AI Grid');
  });

  test('capitalizes the email local part', () {
    expect(defaultGridName(email: 'huy@gmail.com'), 'Huy AI Grid');
  });

  test('takes only the first name from a dotted local part', () {
    expect(defaultGridName(email: 'john.doe@example.com'), 'John AI Grid');
  });

  test('normalizes mixed case', () {
    expect(defaultGridName(email: 'HUY@gmail.com'), 'Huy AI Grid');
  });

  test('handles other local-part separators', () {
    expect(defaultGridName(email: 'jane_smith@x.io'), 'Jane AI Grid');
    expect(defaultGridName(email: 'amy+promo@x.io'), 'Amy AI Grid');
  });

  test('falls back to "My AI Grid" when there is no usable name or email', () {
    expect(defaultGridName(), 'My AI Grid');
    expect(defaultGridName(email: ''), 'My AI Grid');
    expect(defaultGridName(email: '@gmail.com'), 'My AI Grid');
  });
}
