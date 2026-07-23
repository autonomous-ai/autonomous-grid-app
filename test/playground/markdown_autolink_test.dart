import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/playground/logic/chat_message.dart';
import 'package:grid_app/features/playground/presentation/chat_bubble.dart';
import 'package:grid_app/shared/theme/app_theme.dart';

/// Autolinking is GitHub Flavored Markdown's job now, not the message parser's.
/// These pin the behaviour at the level that matters — what ends up on screen —
/// so the hand-rolled version can stay deleted.
void main() {
  Future<void> pump(WidgetTester tester, String text) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 760,
            child: SingleChildScrollView(
              child: ChatBubble(
                message: ChatMessage(role: ChatRole.assistant, text: text),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Every span carrying a tap recogniser, i.e. rendered as a link.
  ///
  /// Walks [SelectableText] rather than [RichText]: with `selectable: true` the
  /// markdown widget builds selectable spans, and there is no RichText to find.
  List<String> linkTexts(WidgetTester tester) {
    final found = <String>[];
    void walk(InlineSpan span) {
      if (span is TextSpan) {
        if (span.recognizer is TapGestureRecognizer &&
            (span.text ?? '').isNotEmpty) {
          found.add(span.text!);
        }
        for (final child in span.children ?? const <InlineSpan>[]) {
          walk(child);
        }
      }
    }

    for (final element in find.byType(SelectableText).evaluate()) {
      final span = (element.widget as SelectableText).textSpan;
      if (span != null) walk(span);
    }
    return found;
  }

  /// The full rendered text of the turn, across selectable spans.
  String plainText(WidgetTester tester) => find
      .byType(SelectableText)
      .evaluate()
      .map((e) => (e.widget as SelectableText).textSpan?.toPlainText() ?? '')
      .join('\n');

  testWidgets('a bare url becomes a tappable link', (tester) async {
    await pump(tester, 'see https://example.com/page now');
    expect(linkTexts(tester), contains('https://example.com/page'));
  });

  testWidgets('a url inside a fence stays literal', (tester) async {
    await pump(
      tester,
      "Here:\n```js\nfetch('https://api.example.com/posts')\n```\ndone",
    );
    // Nothing in the code block is a link, and the code is not rewritten.
    expect(linkTexts(tester), isEmpty);
    expect(
      find.textContaining("fetch('https://api.example.com/posts')"),
      findsOneWidget,
    );
  });

  testWidgets('a url inside a code span stays literal', (tester) async {
    await pump(tester, 'run `curl https://example.com` now');
    expect(linkTexts(tester), isEmpty);
  });

  testWidgets('a full stop after a url stays out of the link', (tester) async {
    await pump(tester, 'go to https://example.com.');
    expect(linkTexts(tester), contains('https://example.com'));
  });

  testWidgets('a single newline is kept as a line break', (tester) async {
    // CommonMark folds these into a space; models use them as real breaks, so
    // softLineBreak is on. Verse and addresses depend on it.
    await pump(tester, 'Bác đi tìm đường cứu nước\nNăm mươi chín năm xa quê');
    expect(plainText(tester), contains('\n'));
  });
}
