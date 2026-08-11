import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/shared/layouts/shell_state.dart';

void main() {
  group('settings sections', () {
    test('the developer-only tabs are gated', () {
      expect(ShellSection.grids.devOnly, isTrue);
      expect(ShellSection.debug.devOnly, isTrue);
      expect(ShellSection.messages.devOnly, isTrue);
      // Customize ships partially, which the three used to be gated to prevent
      // ("together or not at all"). Plugins is the one held back on purpose:
      // Codex has no plugin manager to drive at any version, so its plane is
      // permanently null and the screen would tell an end user their agent
      // can't do this.
      expect(ShellSection.plugins.devOnly, isTrue);
      // Everything an end user needs stays visible in every build.
      expect(ShellSection.agents.devOnly, isFalse);
      expect(ShellSection.skills.devOnly, isFalse);
      expect(ShellSection.connectors.devOnly, isFalse);
      expect(ShellSection.engines.devOnly, isFalse);
      expect(ShellSection.guide.devOnly, isFalse);
      expect(ShellSection.appearance.devOnly, isFalse);
      expect(ShellSection.archived.devOnly, isFalse);
    });

    // The reason Customize may now ship with a hole in it. Gating the last
    // public row would take the heading with it silently — this pins that a
    // release build still draws the group, so the regression shows up here
    // rather than as a missing section on someone's screen.
    test('Customize survives into a release build, minus Plugins', () {
      final customize = visibleSettingsGroups(
        where: (s) => !s.devOnly,
      ).where((g) => g.title == 'Customize');
      expect(customize, hasLength(1));
      expect(customize.single.sections, [
        // Agents leads the group: which assistant runs is the choice the rows
        // under it modify.
        ShellSection.agents,
        ShellSection.skills,
        ShellSection.connectors,
      ]);
    });

    // Copy that names where a screen lives goes stale when a screen moves, and
    // the app has shipped a wrong "Settings ▸ Agents" once already. This pins
    // the current answer: Agents is a settings screen, so the shell draws it
    // full-screen with the settings nav, and the sidebar never lists it.
    test('Agents is reached through Settings, not the sidebar', () {
      expect(ShellSection.agents.isSettings, isTrue);
      expect(kSidebarSections, isNot(contains(ShellSection.agents)));
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
