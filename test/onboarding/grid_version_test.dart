import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/onboarding/grid_version.dart';

void main() {
  group('parseGridVersion', () {
    test('reads the numbers out of a --version line', () {
      expect(parseGridVersion('grid 0.2.0'), (major: 0, minor: 2, patch: 0));
    });

    test('is null when the build printed no version', () {
      expect(parseGridVersion(''), isNull);
      expect(parseGridVersion('grid'), isNull);
    });
  });

  group('isSupportedGridVersion', () {
    test('accepts the minimum and anything newer', () {
      expect(isSupportedGridVersion((major: 0, minor: 2, patch: 0)), isTrue);
      expect(isSupportedGridVersion((major: 0, minor: 2, patch: 7)), isTrue);
      expect(isSupportedGridVersion((major: 0, minor: 3, patch: 0)), isTrue);
      expect(isSupportedGridVersion((major: 1, minor: 0, patch: 0)), isTrue);
    });

    test('rejects the Homebrew-era CLI, which has no `agent install`', () {
      expect(isSupportedGridVersion((major: 0, minor: 1, patch: 15)), isFalse);
      expect(isSupportedGridVersion((major: 0, minor: 1, patch: 99)), isFalse);
    });

    test('an unreadable version passes — a source checkout prints none', () {
      expect(isSupportedGridVersion(null), isTrue);
    });
  });

  test('the outdated message says what to do', () {
    final message = outdatedGridMessage('grid 0.1.15');
    expect(message, contains('out of date'));
    expect(message, contains('0.2.0'));
    expect(message, contains('Update Grid'));
  });
}
