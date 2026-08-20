import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/workflow_bubble_open.dart';

void main() {
  test('defaults closed and toggles', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(workflowBubbleOpenProvider), isFalse);

    container.read(workflowBubbleOpenProvider.notifier).toggle();

    expect(container.read(workflowBubbleOpenProvider), isTrue);
  });
}
