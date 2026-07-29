import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/shared/layouts/shell_state.dart';

void main() {
  group('settings sections', () {
    test('the developer-only tabs are gated', () {
      expect(ShellSection.grids.devOnly, isTrue);
      expect(ShellSection.debug.devOnly, isTrue);
      // Messages (Integrations) is gated; so is the whole Customize group —
      // Skills, Connectors and Plugins ship together or not at all, so a
      // build never shows one extension screen without its siblings.
      expect(ShellSection.messages.devOnly, isTrue);
      expect(ShellSection.skills.devOnly, isTrue);
      expect(ShellSection.connectors.devOnly, isTrue);
      expect(ShellSection.plugins.devOnly, isTrue);
      // Everything an end user needs stays visible in every build.
      expect(ShellSection.engines.devOnly, isFalse);
      expect(ShellSection.guide.devOnly, isFalse);
      expect(ShellSection.appearance.devOnly, isFalse);
      expect(ShellSection.archived.devOnly, isFalse);
    });

    // The flat list is what isSettings tests against, so a row that appears in
    // the nav must count as a settings screen — and nothing may count as one
    // without appearing.
    test('the flat list is exactly the grouped rows', () {
      final grouped = [for (final g in kSettingsGroups) ...g.sections];
      expect(kSettingsSections, grouped);
      expect(
        kSettingsSections.toSet().length,
        kSettingsSections.length,
        reason: 'a section listed in two groups would draw twice in the nav',
      );
    });

    // With groups the old "visible rows form one unbroken run" rule no longer
    // applies — a developer-only group drops out whole, heading included, so a
    // gap in the flat order costs an end user nothing. What must hold instead:
    // no heading is ever drawn over an empty run.
    test('a group with no visible rows drops out entirely', () {
      final groups = visibleSettingsGroups(
        where: (s) => s != ShellSection.grids,
      );
      expect(groups.every((g) => g.sections.isNotEmpty), isTrue);
      // Filtering everything away leaves no headings at all, rather than a
      // column of captions over nothing.
      expect(visibleSettingsGroups(where: (_) => false), isEmpty);
    });

    test('filtering keeps a group\'s surviving rows in their listed order', () {
      final kept = visibleSettingsGroups(
        where: (s) => s != ShellSection.appearance,
      );
      final personal = kept.firstWhere((g) => g.title == 'Personal');
      expect(personal.sections, isNot(contains(ShellSection.appearance)));
      expect(personal.sections, [
        for (final s in kSettingsGroups.first.sections)
          if (s != ShellSection.appearance) s,
      ]);
    });

    test('Archived chats is the last row in the list', () {
      expect(ShellSection.archived.devOnly, isFalse);
      expect(kSettingsSections.last, ShellSection.archived);
    });

    test('the default settings screen is one every build can show, so an end '
        'user never lands on a developer-only tab', () {
      expect(kDefaultSettingsSection.devOnly, isFalse);
      expect(kSettingsSections, contains(kDefaultSettingsSection));
    });
  });
}
