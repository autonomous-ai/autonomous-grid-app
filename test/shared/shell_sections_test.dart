import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/shared/layouts/shell_state.dart';

void main() {
  group('settings sections', () {
    test('Grids and Debug are the developer-only tabs', () {
      expect(ShellSection.grids.devOnly, isTrue);
      expect(ShellSection.debug.devOnly, isTrue);
      // Everything an end user needs stays visible in every build.
      expect(ShellSection.engines.devOnly, isFalse);
      expect(ShellSection.messages.devOnly, isFalse);
      expect(ShellSection.guide.devOnly, isFalse);
    });

    test('Grids sits just above Debug at the bottom of the list', () {
      final grids = kSettingsSections.indexOf(ShellSection.grids);
      final debug = kSettingsSections.indexOf(ShellSection.debug);
      expect(grids, debug - 1);
      expect(debug, kSettingsSections.length - 1);
    });

    test('the default settings screen is one every build can show, so an end '
        'user never lands on a developer-only tab', () {
      expect(kDefaultSettingsSection.devOnly, isFalse);
      expect(kSettingsSections, contains(kDefaultSettingsSection));
    });
  });
}
