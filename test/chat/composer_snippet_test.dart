import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/chat/logic/composer_snippet.dart';

void main() {
  group('how a selection points at where it came from', () {
    test('carries the lines it covers, so an assistant that has already edited '
        'above them can still find them', () {
      final snippet = snippetOf(
        path: '/repo/lib/main.dart',
        text: 'log(a);',
        startLine: 11,
        endLine: 12,
      )!;

      expect(snippet.reference, '/repo/lib/main.dart:11-12');
      expect(
        messageWithSnippets('Why?', [snippet]),
        contains('main.dart:11-12'),
      );
    });

    test('one line reads as one line rather than as a range', () {
      final snippet = snippetOf(
        path: '/repo/lib/main.dart',
        text: 'log(a);',
        startLine: 11,
        endLine: 11,
      )!;

      expect(snippet.reference, '/repo/lib/main.dart:11');
    });

    test('a surface that cannot say which lines were picked names the file and '
        'stops there — no numbers is better than invented ones', () {
      final snippet = snippetOf(path: '/repo/README.md', text: 'abc')!;

      expect(snippet.reference, '/repo/README.md');
      expect(snippet.lineRange, '');
    });

    test('a selection cut at the budget drops its numbers: the text no longer '
        'reaches the line it claimed to end on', () {
      final snippet = snippetOf(
        path: '/repo/lib/main.dart',
        text: 'x' * (kSnippetBudget + 10),
        startLine: 1,
        endLine: 400,
      )!;

      expect(snippet.truncated, isTrue);
      expect(snippet.reference, '/repo/lib/main.dart');
      expect(snippet.text.length, kSnippetBudget);
    });
  });
}
