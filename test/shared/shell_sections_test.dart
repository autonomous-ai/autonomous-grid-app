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
      expect(ShellSection.appearance.devOnly, isFalse);
    });

    // The order below interleaves Appearance with the developer-only rows, so
    // what matters isn't its raw index — it's that a shipped build still ends on
    // it. That holds as long as everything after it is developer-only.
    test('a shipped build\'s settings list ends at Appearance', () {
      expect(ShellSection.appearance.isVisibleForBuild, isTrue);
      final appearance = kSettingsSections.indexOf(ShellSection.appearance);
      expect(appearance, greaterThan(-1));
      expect(
        kSettingsSections.skip(appearance + 1).every((s) => s.devOnly),
        isTrue,
        reason:
            'a tab an end user can see now sits below Appearance, so their '
            'list no longer ends there',
      );
    });

    test('Debug stays at the very bottom', () {
      final debug = kSettingsSections.indexOf(ShellSection.debug);
      expect(debug, kSettingsSections.length - 1);
    });

    test('the default settings screen is one every build can show, so an end '
        'user never lands on a developer-only tab', () {
      expect(kDefaultSettingsSection.devOnly, isFalse);
      expect(kSettingsSections, contains(kDefaultSettingsSection));
    });
  });
}
