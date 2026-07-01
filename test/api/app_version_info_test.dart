import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/api/models/app_version_info.dart';

void main() {
  group('AppVersionInfo.fromJson', () {
    const raw = '''
    {
      "version": "0.3.0",
      "notes": "Bug fixes and speed improvements.",
      "mandatory": false,
      "platforms": {
        "macos": {"url": "https://dl.example/Grid-0.3.0.dmg", "sha256": "abc", "size": 84213456, "min_supported": "0.2.0"},
        "windows": {"url": "https://dl.example/Grid-0.3.0-setup.exe"}
      }
    }''';

    test('parses version, notes and per-platform releases', () {
      final info =
          AppVersionInfo.fromJson(jsonDecode(raw) as Map<String, dynamic>);

      expect(info.version, '0.3.0');
      expect(info.notes, 'Bug fixes and speed improvements.');
      expect(info.mandatory, isFalse);

      final mac = info.releaseFor('macos');
      expect(mac?.url, 'https://dl.example/Grid-0.3.0.dmg');
      expect(mac?.sha256, 'abc');
      expect(mac?.sizeBytes, 84213456);
      expect(mac?.minSupported, '0.2.0');
      expect(mac?.hasUrl, isTrue);

      expect(info.releaseFor('windows')?.sizeBytes, isNull);
      expect(info.releaseFor('linux'), isNull);
    });

    test('tolerates a missing/blank fields payload', () {
      final info = AppVersionInfo.fromJson(
          jsonDecode('{"version": "0.4.0", "notes": "   "}')
              as Map<String, dynamic>);

      expect(info.version, '0.4.0');
      expect(info.notes, isNull);
      expect(info.mandatory, isFalse);
      expect(info.platforms, isEmpty);
    });
  });
}
