import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/shared/code/code_highlight.dart';

/// The highlighter is picked for *coverage*: a coding agent emits python,
/// bash and typescript far more often than dart. The TextMate-based
/// alternative ships five grammars and none of those three, which is the whole
/// reason this package is the one wired up.
void main() {
  const base = TextStyle(fontSize: 12.5);

  int countSpans(TextSpan? span) {
    if (span == null) return 0;
    var n = span.text == null ? 0 : 1;
    for (final child in span.children ?? const <InlineSpan>[]) {
      if (child is TextSpan) n += countSpans(child);
    }
    return n;
  }

  test('covers the languages an agent actually emits', () {
    for (final lang in [
      'python',
      'bash',
      'javascript',
      'typescript',
      'dart',
      'go',
      'rust',
      'json',
      'yaml',
      'sql',
    ]) {
      expect(CodeHighlight.supports(lang), isTrue, reason: 'missing $lang');
    }
  });

  test('normalises the aliases models write on a fence', () {
    for (final alias in ['py', 'js', 'ts', 'sh', 'shell', 'yml', 'rs']) {
      expect(CodeHighlight.supports(alias), isTrue, reason: 'missing $alias');
    }
  });

  test('produces more than one coloured span for real code', () {
    final span = CodeHighlight.spans(
      code: 'def greet(name):\n    return f"hello {name}"',
      language: 'python',
      base: base,
      brightness: Brightness.dark,
    );
    // A keyword, an identifier and a string should not all share one span.
    expect(countSpans(span), greaterThan(3));
  });

  test('an unknown language falls back to plain, not a crash', () {
    expect(
      CodeHighlight.spans(
        code: 'whatever',
        language: 'not-a-language',
        base: base,
        brightness: Brightness.dark,
      ),
      isNull,
    );
  });

  test('a half-written fragment does not throw', () {
    expect(
      () => CodeHighlight.spans(
        code: 'def greet(name):\n    return f"hel',
        language: 'python',
        base: base,
        brightness: Brightness.light,
      ),
      returnsNormally,
    );
  });

  group('remembering what it has already coloured', () {
    setUp(CodeHighlight.forgetHighlights);

    test('the same line under the same theme is answered from memory, not '
        'parsed again — a diff redraws its lines on every scroll, and at '
        '~170µs each a screenful is half a frame spent twice', () {
      const line = 'final files = ref.watch(reviewProvider(folder));';

      final first = CodeHighlight.spans(
        code: line,
        language: 'dart',
        base: base,
        brightness: Brightness.dark,
      );
      final second = CodeHighlight.spans(
        code: line,
        language: 'dart',
        base: base,
        brightness: Brightness.dark,
      );

      expect(first, isNotNull);
      expect(identical(first, second), isTrue);
    });

    test('the other theme is a different answer, so a theme flip re-colours '
        'instead of handing back the dark spans on a light page', () {
      const line = 'final x = 1;';

      final dark = CodeHighlight.spans(
        code: line,
        language: 'dart',
        base: base,
        brightness: Brightness.dark,
      );
      final light = CodeHighlight.spans(
        code: line,
        language: 'dart',
        base: base,
        brightness: Brightness.light,
      );

      expect(identical(dark, light), isFalse);
    });

    test('a bigger code size is a different answer too — the size is baked '
        'into the spans, and the user can change it', () {
      const line = 'final x = 1;';

      final small = CodeHighlight.spans(
        code: line,
        language: 'dart',
        base: const TextStyle(fontSize: 12),
        brightness: Brightness.dark,
      );
      final large = CodeHighlight.spans(
        code: line,
        language: 'dart',
        base: const TextStyle(fontSize: 18),
        brightness: Brightness.dark,
      );

      expect(small!.style?.fontSize, 12);
      expect(large!.style?.fontSize, 18);
    });
  });
}
