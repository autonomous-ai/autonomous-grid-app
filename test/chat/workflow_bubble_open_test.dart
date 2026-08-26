import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/workflow_bubble_open.dart';

void main() {
  // Open by default, because a routed chat's overview is the feature rather
  // than something to go and find: the strip has to appear on its own, and the
  // top-bar button is there to put it away.
  test('starts open so a routed chat shows its overview unprompted', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(workflowBubbleOpenProvider), isTrue);
  });

  test(
    'toggles back and forth so the button can hide and restore the strip',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(workflowBubbleOpenProvider.notifier).toggle();
      expect(container.read(workflowBubbleOpenProvider), isFalse);

      container.read(workflowBubbleOpenProvider.notifier).toggle();
      expect(container.read(workflowBubbleOpenProvider), isTrue);
    },
  );
}
