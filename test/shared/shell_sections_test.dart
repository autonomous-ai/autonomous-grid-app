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

    // The order interleaves the end-user rows with the developer-only ones, so
    // what matters isn't any single index — it's that the visible rows form one
    // unbroken run at the top. Archived chats is the last of them: it's where a
    // chat goes when it leaves the sidebar, so it belongs with the rows an end
    // user actually visits rather than behind the developer gate.
    test('a shipped build\'s settings list ends at Archived chats', () {
      expect(ShellSection.archived.isVisibleForBuild, isTrue);
      expect(ShellSection.archived.devOnly, isFalse);
      final archived = kSettingsSections.indexOf(ShellSection.archived);
      expect(archived, greaterThan(-1));
      expect(
        kSettingsSections.skip(archived + 1).every((s) => s.devOnly),
        isTrue,
        reason:
            'a tab an end user can see now sits below Archived chats, so their '
            'list no longer ends there',
      );
    });

    // The rule the test above rests on: an end user sees a contiguous list, not
    // one with a gap where a developer-only row was filtered out of the middle.
    test('no end-user tab hides below a developer-only one', () {
      final visible = [
        for (final (i, s) in kSettingsSections.indexed)
          if (!s.devOnly) i,
      ];
      expect(
        visible,
        List.generate(visible.length, (i) => i),
        reason: 'the rows an end user sees must be the first ones in the list',
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
