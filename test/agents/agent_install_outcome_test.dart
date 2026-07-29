import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';
import 'package:grid_app/features/agents/logic/agent_install_controller.dart';

/// The line the Update/Install button shows when it finishes. Since the app
/// can't know a newer build exists until it has pulled one, the wording turns on
/// the before/after comparison, and must never claim an up-to-date it can't back.
void main() {
  String outcome({bool upgrade = true, String? before, String? after}) =>
      agentInstallOutcome(
        AgentTool.hermes,
        upgrade: upgrade,
        before: before,
        after: after,
      );

  test('an update that changed nothing reads as already up to date, not as an '
      'update that did nothing', () {
    expect(
      outcome(before: '0.19.0', after: '0.19.0'),
      'Hermes is already up to date · v0.19.0',
    );
  });

  test('an update to a newer build names the version it moved to', () {
    expect(
      outcome(before: '0.19.0', after: '0.20.0'),
      'Updated Hermes to v0.20.0',
    );
  });

  test('an update whose build reports no version is only a reinstall — never '
      'claimed up to date on evidence it lacks', () {
    expect(outcome(before: '0.19.0', after: null), 'Reinstalled Hermes.');
    // Even when there was no known "before" either, it stays a reinstall.
    expect(outcome(before: null, after: null), 'Reinstalled Hermes.');
  });

  test('a fresh install names the build it put on the machine', () {
    expect(
      outcome(upgrade: false, before: null, after: '0.19.0'),
      'Installed Hermes · v0.19.0',
    );
    expect(
      outcome(upgrade: false, before: null, after: null),
      'Installed Hermes.',
    );
  });
}
