import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/app_update/logic/version_compare.dart';

void main() {
  group('compareVersions', () {
    test('equal versions compare to zero', () {
      expect(compareVersions('1.2.3', '1.2.3'), 0);
    });

    test('orders by numeric segments', () {
      expect(compareVersions('0.3.0', '0.2.9'), greaterThan(0));
      expect(compareVersions('0.2.0', '0.10.0'), lessThan(0));
    });

    test('missing trailing segments count as zero', () {
      expect(compareVersions('1.2', '1.2.0'), 0);
      expect(compareVersions('1.2.1', '1.2'), greaterThan(0));
    });

    test('a pre-release ranks below the same core version', () {
      expect(compareVersions('1.0.0-rc1', '1.0.0'), lessThan(0));
      expect(compareVersions('1.0.0', '1.0.0-rc1'), greaterThan(0));
      expect(compareVersions('1.0.0-alpha', '1.0.0-beta'), lessThan(0));
    });

    test('build metadata is ignored', () {
      expect(compareVersions('1.0.0+build.7', '1.0.0'), 0);
    });

    test('non-numeric junk never throws and compares low', () {
      expect(compareVersions('abc', '0.0.1'), lessThan(0));
    });
  });

  group('isNewerVersion', () {
    test('true only when latest strictly exceeds current', () {
      expect(isNewerVersion(current: '0.2.0', latest: '0.3.0'), isTrue);
      expect(isNewerVersion(current: '0.2.0', latest: '0.2.0'), isFalse);
      expect(isNewerVersion(current: '0.3.0', latest: '0.2.0'), isFalse);
    });
  });
}
