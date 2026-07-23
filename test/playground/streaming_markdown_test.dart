import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';
import 'package:grid_app/features/playground/presentation/chat_bubble.dart';
import 'package:grid_app/shared/theme/app_theme.dart';

/// A streamed reply arrives a chunk at a time, so the transcript spends most of
/// its life holding *invalid* markdown — a bold that hasn't closed, a fence with
/// no terminator, a table missing its last cell.
///
/// Web chat UIs patch this before parsing (Vercel ships a whole package,
/// `remend`, to close dangling syntax). These pin that the renderer already
/// tolerates the fragments, which is why this app carries no such dependency —
/// if one of these ever starts throwing, that decision needs revisiting.
void main() {
  const fragments = {
    'unclosed bold': 'here is **bold',
    'unclosed inline code': 'run `npm inst',
    'unclosed link': 'see [the docs](https://exa',
    'unclosed fence': 'code:\n```dart\nvoid main() {',
    'unclosed table': '| a | b |\n|---|---|\n| 1 |',
    'unclosed math': r'the value $$\frac{1}{2',
  };

  for (final entry in fragments.entries) {
    testWidgets('mid-stream ${entry.key} renders without throwing', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildAppTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 800,
              child: SingleChildScrollView(
                child: ChatBubble(
                  message: ChatMessage(
                    role: ChatRole.assistant,
                    text: entry.value,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}
