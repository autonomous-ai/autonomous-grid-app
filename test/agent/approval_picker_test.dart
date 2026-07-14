import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/agent_permissions.dart';
import 'package:grid_app/features/agent/presentation/approval_picker.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';
import 'package:grid_app/infrastructure/state/chat_prefs_store.dart';

void main() {
  late Directory tmp;
  late File file;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_approval_test');
    file = File('${tmp.path}/chat_prefs.json');
  });
  tearDown(() => tmp.delete(recursive: true));

  Future<ProviderContainer> pump(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        chatPrefsStoreProvider.overrideWithValue(ChatPrefsStore(file: file)),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: Center(child: ApprovalPicker())),
        ),
      ),
    );
    return container;
  }

  testWidgets('it opens asking first — the cautious mode, not the fast one', (
    tester,
  ) async {
    final container = await pump(tester);

    expect(find.text('Ask before acting'), findsOneWidget);
    expect(container.read(agentApprovalModeProvider), AgentApprovalMode.ask);
  });

  testWidgets('the menu says what each mode really costs', (tester) async {
    await pump(tester);

    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();

    expect(find.text('Read only'), findsOneWidget);
    expect(find.text('Full access'), findsOneWidget);
    expect(
      find.text(
        'It runs commands and changes your files without asking. '
        'Nothing to undo.',
      ),
      findsOneWidget,
      reason: 'the mode that stops asking must not be sold as a convenience',
    );
  });

  testWidgets('picking a mode applies it and remembers it for next launch', (
    tester,
  ) async {
    final container = await pump(tester);

    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Full access'));
    await tester.pumpAndSettle();

    expect(container.read(agentApprovalModeProvider), AgentApprovalMode.full);
    // On disk, so the next launch honours it rather than quietly asking again.
    expect(ChatPrefsStore(file: file).load().approval, AgentApprovalMode.full);
  });
}
