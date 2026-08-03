import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/chat_sessions_controller.dart';
import 'package:grid_app/features/chat/logic/chat_store.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
import 'package:grid_app/features/chat/presentation/archived_chats_view.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The controls bar is hidden when nothing is archived and shown otherwise —
/// these find it by its search field's placeholder.
final _searchField = find.text('Search archived chats');
final _deleteAll = find.text('Delete all');

Conversation _chat({
  required String id,
  String title = 'Chat',
  DateTime? archivedAt,
}) => Conversation(
  id: id,
  title: title,
  model: 'm',
  createdAt: DateTime(2026, 1, 1),
  updatedAt: DateTime(2026, 1, 1),
  archivedAt: archivedAt,
  messages: const [ChatMessage(role: ChatRole.user, text: 'hello')],
);

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('archived_view'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Show the screen over a temp store seeded with [seed], with the saved chats
  /// already read back in — they land off the first frame now, so a pumped tree
  /// starts empty until that read completes.
  Future<void> pumpView(WidgetTester tester, List<Conversation> seed) async {
    final store = ChatStore(directory: tmp);
    for (final c in seed) {
      store.save(c);
    }
    final container = ProviderContainer(
      overrides: [chatStoreProvider.overrideWithValue(store)],
    );
    addTearDown(container.dispose);
    // Through [WidgetTester.runAsync], because the read is real file I/O: the
    // test binding's zone parks a plain await on it forever.
    await tester.runAsync(
      () => container.read(chatSessionsProvider.notifier).restored,
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: Scaffold(body: ArchivedChatsView())),
      ),
    );
    await tester.pump();
  }

  testWidgets('nothing archived: the whole controls bar is hidden', (
    tester,
  ) async {
    await pumpView(tester, [_chat(id: 'live')]);

    expect(find.text('No archived chats'), findsOneWidget);
    // Search, the filters and Delete all would all be dead ends over an empty
    // list, so none of them is on screen.
    expect(_searchField, findsNothing);
    expect(_deleteAll, findsNothing);
    expect(find.text('All chats'), findsNothing);
    expect(find.text('Recently archived'), findsNothing);
  });

  testWidgets('with archived chats the controls are back', (tester) async {
    await pumpView(tester, [
      _chat(id: 'a', title: 'Deploy', archivedAt: DateTime(2026, 6, 1)),
    ]);

    expect(_searchField, findsOneWidget);
    expect(_deleteAll, findsOneWidget);
    expect(find.text('Deploy'), findsOneWidget);
    expect(find.text('No archived chats'), findsNothing);
  });

  testWidgets('the group "…" sits at the right edge, not mid-row', (
    tester,
  ) async {
    // Regression: the label cluster was Flexible and the trailing Spacer was
    // too, so as two flex-1 children they split the free space evenly and
    // parked the button in the middle of the row.
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await pumpView(tester, [
      _chat(id: 'a', title: 'Deploy', archivedAt: DateTime(2026, 6, 1)),
    ]);

    final button = find.byIcon(LucideIcons.ellipsis300);
    final row = find.ancestor(of: button, matching: find.byType(Row)).first;
    final rowRect = tester.getRect(row);
    final buttonRect = tester.getRect(button);

    // Within a hair of the row's trailing edge, rather than somewhere near its
    // middle. The button is 16px wide inside a 26px hit target.
    expect(
      rowRect.right - buttonRect.right,
      lessThan(16),
      reason: 'the "…" drifted away from the row edge',
    );
    // And the count stays beside the name it belongs to, not dragged out with
    // the button (which is what Expanded on the name alone did).
    final nameRect = tester.getRect(find.text('Outside projects'));
    final countRect = tester.getRect(find.text('1 chat'));
    expect(countRect.left - nameRect.right, lessThan(20));
  });

  testWidgets('filtered to nothing keeps the controls — the way back out', (
    tester,
  ) async {
    await pumpView(tester, [
      _chat(id: 'a', title: 'Deploy', archivedAt: DateTime(2026, 6, 1)),
    ]);

    await tester.enterText(find.byType(TextField), 'zzzz no such chat');
    await tester.pump();

    expect(find.text('No matches'), findsOneWidget);
    // The critical difference from the empty case: without these the user
    // could never clear the query that emptied the list.
    expect(_searchField, findsOneWidget);
    expect(_deleteAll, findsOneWidget);
  });
}
