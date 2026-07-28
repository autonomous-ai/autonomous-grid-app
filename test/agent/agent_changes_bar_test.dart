import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/agent_changes.dart';

/// The bar summarising the agent's edits is a transient notice, not a fixture:
/// these pin the three ways it should leave the screen — a hand dismiss, the
/// auto-hide countdown, and leaving the conversation — while proving none of them
/// throws away the undo the bar is a shortcut to.
void main() {
  ProviderContainer container({
    Duration autoHide = const Duration(seconds: 10),
  }) {
    final c = ProviderContainer(
      overrides: [agentChangesAutoHideProvider.overrideWithValue(autoHide)],
    );
    addTearDown(c.dispose);
    // Read the bar so its listener on the change list is live before any edit.
    c.read(agentChangesBarProvider);
    return c;
  }

  // Let the bar's listener flush after a change to the underlying list.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('stays hidden until the agent actually changes a file', () {
    final c = container();
    expect(c.read(agentChangesBarProvider), isFalse);
  });

  test('shows once the agent records a change', () async {
    final c = container();
    c
        .read(agentChangesProvider.notifier)
        .record(path: '/tmp/a.txt', before: 'old', after: 'new');
    await settle();
    expect(c.read(agentChangesBarProvider), isTrue);
  });

  test('dismiss hides the bar but keeps the change, so a later edit '
      'brings it back over the whole set', () async {
    final c = container();
    final changes = c.read(agentChangesProvider.notifier);
    changes.record(path: '/tmp/a.txt', before: 'old', after: 'new');
    await settle();

    c.read(agentChangesBarProvider.notifier).dismiss();
    expect(c.read(agentChangesBarProvider), isFalse);
    // The snapshot is still there — hiding is not undoing.
    expect(c.read(agentChangesProvider), hasLength(1));

    changes.record(path: '/tmp/b.txt', before: 'x', after: 'y');
    await settle();
    expect(c.read(agentChangesBarProvider), isTrue);
    expect(c.read(agentChangesProvider), hasLength(2));
  });

  test('hides itself once the auto-hide delay passes, leaving the undo '
      'data intact', () async {
    final c = container(autoHide: const Duration(milliseconds: 30));
    c
        .read(agentChangesProvider.notifier)
        .record(path: '/tmp/a.txt', before: 'old', after: 'new');
    await settle();
    expect(c.read(agentChangesBarProvider), isTrue);

    await Future<void>.delayed(const Duration(milliseconds: 90));
    expect(c.read(agentChangesBarProvider), isFalse);
    expect(c.read(agentChangesProvider), hasLength(1));
  });

  test(
    'leaving the conversation (clear) drops the bar with the changes',
    () async {
      final c = container();
      final changes = c.read(agentChangesProvider.notifier);
      changes.record(path: '/tmp/a.txt', before: 'old', after: 'new');
      await settle();
      expect(c.read(agentChangesBarProvider), isTrue);

      changes.clear();
      await settle();
      expect(c.read(agentChangesBarProvider), isFalse);
      expect(c.read(agentChangesProvider), isEmpty);
    },
  );
}
