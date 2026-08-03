import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/chat_sessions_controller.dart';
import 'package:grid_app/features/chat/logic/chat_store.dart';
import 'package:grid_app/features/chat/logic/conversation.dart';
import 'package:grid_app/features/chat/presentation/chat_header.dart';

/// The chat "…" menu's rows follow the design system's §5 recipe. Geometry is
/// *measured* here rather than read off the source: the menu is positioned by
/// summing its own row heights, so a row that renders taller than the constant
/// says slides the whole panel off its button — the exact failure that made
/// visualDensity worth pinning in the first place.

/// Opens the chat header's "…" menu and settles it.
///
/// The open chat is seeded into a temp store here. It used to come from
/// whatever was in the developer's own `~/.grid` — the menu only exists when a
/// chat is open, so this passed on a machine with a chat history and would have
/// found no button anywhere else.
Future<void> _openMenu(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1000, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final dir = Directory.systemTemp.createTempSync('chat_menu_row');
  addTearDown(() => dir.deleteSync(recursive: true));
  ChatStore(directory: dir).save(
    Conversation(
      id: 'open',
      title: 'Deploy notes',
      model: 'm',
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
      messages: const [ChatMessage(role: ChatRole.user, text: 'hello')],
    ),
  );
  final container = ProviderContainer(
    overrides: [chatStoreProvider.overrideWithValue(ChatStore(directory: dir))],
  );
  addTearDown(container.dispose);
  // Through [WidgetTester.runAsync]: reading the saved chats is real file I/O,
  // which the test binding's zone parks a plain await on forever.
  await tester.runAsync(
    () => container.read(chatSessionsProvider.notifier).restored,
  );

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const _MenuHarness(),
    ),
  );
  await tester.pumpAndSettle();

  await tester.tap(find.byTooltip('Chat options'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('every menu row measures the height the menu is sized from', (
    tester,
  ) async {
    await _openMenu(tester);

    // All four labels are on screen, so the menu opened and nothing clipped.
    for (final label in const [
      'Rename chat',
      'Archive chat',
      'Copy transcript',
      'Delete chat',
    ]) {
      expect(find.text(label), findsOneWidget, reason: '$label missing');
    }

    // Each row's tappable box is exactly _rowHeight (34) tall. Measured from
    // the InkWell, which is what the pointer actually hits.
    for (final label in const [
      'Rename chat',
      'Archive chat',
      'Copy transcript',
      'Delete chat',
    ]) {
      final row = find.ancestor(
        of: find.text(label),
        matching: find.byType(InkWell),
      );
      expect(
        tester.getRect(row.first).height,
        34.0,
        reason: '$label row is not 34px tall — _menuSize would be wrong',
      );
    }
  });

  testWidgets('rows inset 6px from the panel edge, so hover reads as a pill', (
    tester,
  ) async {
    await _openMenu(tester);

    final panel = tester.getRect(
      find
          .ancestor(
            of: find.text('Rename chat'),
            matching: find.byType(SizedBox),
          )
          .last,
    );
    final row = tester.getRect(
      find
          .ancestor(
            of: find.text('Rename chat'),
            matching: find.byType(InkWell),
          )
          .first,
    );

    // The gutter is what keeps the highlight from going full-bleed.
    expect(row.left - panel.left, 6.0);
    expect(panel.right - row.right, 6.0);
  });

  testWidgets('labels share one left edge whatever the glyph', (tester) async {
    await _openMenu(tester);

    final lefts = <double>{
      for (final label in const [
        'Rename chat',
        'Archive chat',
        'Copy transcript',
        'Delete chat',
      ])
        tester.getRect(find.text(label)).left,
    };

    // A fixed 16px leading slot: four different glyphs, one text column.
    expect(
      lefts.length,
      1,
      reason: 'labels start at different x — leading slot is not fixed',
    );
  });
}

/// A bare app hosting just the header, with a chat already open.
class _MenuHarness extends StatelessWidget {
  const _MenuHarness();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: Scaffold(body: ChatHeader()));
  }
}
