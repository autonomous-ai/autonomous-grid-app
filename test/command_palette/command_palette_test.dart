import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/chat_sessions_controller.dart';
import 'package:grid_app/features/chat/logic/chat_store.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
import 'package:grid_app/features/command_palette/presentation/command_palette.dart';
import 'package:grid_app/features/playground/logic/chat_sender.dart';
import 'package:grid_app/features/playground/logic/playground_request.dart';
import 'package:grid_app/features/projects/logic/project.dart';
import 'package:grid_app/infrastructure/state/models/network_credential.dart';
import 'package:grid_app/shared/layouts/shell_state.dart';

Conversation _chat(String id, String title) => Conversation(
  id: id,
  title: title,
  model: 'm',
  createdAt: DateTime(2026, 7, 14),
  updatedAt: DateTime(2026, 7, 14),
);

class _FakeSender implements ChatSender {
  @override
  Stream<ChatSendUpdate> send({
    required NetworkCredential network,
    required String model,
    required List<ChatMessage> history,
    PlaygroundModality modality = PlaygroundModality.text,
    List<MediaAttachment> attachments = const [],
    String? localBaseUrl,
    String? workdir,
    String? conversationId,
  }) => const Stream.empty();
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_palette_test');
  });
  tearDown(() => tmp.delete(recursive: true));

  Future<ProviderContainer> open(WidgetTester tester) async {
    final store = ChatStore(directory: tmp)
      ..save(_chat('1', 'Fix the login bug'))
      ..save(_chat('2', 'Holiday plan'));
    final container = ProviderContainer(
      overrides: [
        chatStoreProvider.overrideWithValue(store),
        chatSenderProvider.overrideWithValue(_FakeSender()),
        projectsStoreProvider.overrideWithValue(
          ProjectsStore(file: File('${tmp.path}/projects.json')),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: Center(child: CommandPalette())),
        ),
      ),
    );
    return container;
  }

  testWidgets('it opens on your recent chats and the things you can start', (
    tester,
  ) async {
    await open(tester);

    expect(find.text('Chats'), findsOneWidget);
    expect(find.text('Fix the login bug'), findsOneWidget);
    expect(find.text('Suggested'), findsOneWidget);
    expect(find.text('Add a project'), findsOneWidget);
  });

  testWidgets('typing narrows it, and ⏎ opens what is highlighted', (
    tester,
  ) async {
    final container = await open(tester);

    await tester.enterText(find.byType(TextField), 'holiday');
    await tester.pumpAndSettle();
    expect(find.text('Fix the login bug'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    // The chat is open, and the palette is gone.
    expect(container.read(chatSessionsProvider).activeId, '2');
    expect(container.read(shellSectionProvider), ShellSection.chat);
  });

  testWidgets('the number beside a row is the key that opens it', (
    tester,
  ) async {
    final container = await open(tester);
    expect(find.text('⌘1'), findsOneWidget);

    // ⌘2 — the second row, whichever it is.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.meta);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit2);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.meta);
    await tester.pumpAndSettle();

    expect(container.read(chatSessionsProvider).activeId, '2');
  });

  testWidgets(
    'a search that matches nothing says so, instead of an empty box',
    (tester) async {
      await open(tester);

      await tester.enterText(find.byType(TextField), 'zzzz');
      await tester.pumpAndSettle();

      expect(find.text('Nothing matches that.'), findsOneWidget);
    },
  );

  testWidgets('the arrow keys move the highlight instead of the caret', (
    tester,
  ) async {
    final container = await open(tester);

    // Down once: the second chat. ⏎ opens it.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(container.read(chatSessionsProvider).activeId, '2');
  });
}
