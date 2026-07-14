import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/chat_sessions_controller.dart';
import 'package:grid_app/features/chat/logic/chat_store.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
import 'package:grid_app/features/chat/presentation/chat_history_list.dart';
import 'package:grid_app/features/projects/logic/project.dart';
import 'package:grid_app/infrastructure/state/chat_prefs_store.dart';
import 'package:grid_app/shared/layouts/shell_state.dart';
import 'package:grid_app/shared/layouts/widgets/sidebar_item.dart';

Conversation _chat(String id, String title) => Conversation(
  id: id,
  title: title,
  model: 'm',
  createdAt: DateTime(2026, 7, 14),
  updatedAt: DateTime(2026, 7, 14),
);

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_history_list_test');
  });
  tearDown(() => tmp.delete(recursive: true));

  Future<ProviderContainer> pump(WidgetTester tester) async {
    final chats = ChatStore(directory: Directory('${tmp.path}/chats'))
      ..save(_chat('c1', 'Trip ideas'));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatStoreProvider.overrideWithValue(chats),
          projectsStoreProvider.overrideWithValue(
            ProjectsStore(file: File('${tmp.path}/projects.json')),
          ),
          chatPrefsStoreProvider.overrideWithValue(
            ChatPrefsStore(file: File('${tmp.path}/chat_prefs.json')),
          ),
        ],
        child: const MaterialApp(
          home: Scaffold(body: SizedBox(width: 264, child: ChatHistoryList())),
        ),
      ),
    );
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(ChatHistoryList)),
    );
    container.read(chatSessionsProvider.notifier).select('c1');
    await tester.pump();
    return container;
  }

  Finder chatRow(String title) => find.widgetWithText(SidebarItem, title);

  testWidgets('the open chat is highlighted while you are in Chat', (
    tester,
  ) async {
    await pump(tester);

    expect(tester.widget<SidebarItem>(chatRow('Trip ideas')).selected, isTrue);
  });

  testWidgets(
    'leaving Chat unlights it — the highlight says where you are, and '
    'two lit rows in one rail say nothing',
    (tester) async {
      final container = await pump(tester);

      container
          .read(shellSectionProvider.notifier)
          .select(ShellSection.plugins);
      await tester.pump();

      expect(
        tester.widget<SidebarItem>(chatRow('Trip ideas')).selected,
        isFalse,
      );
      expect(
        container.read(chatSessionsProvider).activeId,
        'c1',
        reason:
            'it is still the chat you come back to — just not the open screen',
      );
    },
  );

  testWidgets('coming back to Chat lights it again', (tester) async {
    final container = await pump(tester);
    container.read(shellSectionProvider.notifier).select(ShellSection.plugins);
    await tester.pump();

    container.read(shellSectionProvider.notifier).select(ShellSection.chat);
    await tester.pump();

    expect(tester.widget<SidebarItem>(chatRow('Trip ideas')).selected, isTrue);
  });
}
