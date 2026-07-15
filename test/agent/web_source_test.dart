import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/infrastructure/cli/agent_event.dart';

void main() {
  group('parseWebSearchSources', () {
    test('reads the bulleted title — url lines Hermes formats, skipping the '
        'header and the indented descriptions', () {
      const content = '''
Web results: 2
• Flutter — https://flutter.dev
  Google's UI toolkit for building apps.
• Dart guides — https://dart.dev/guides
  The language behind Flutter.''';

      final sources = parseWebSearchSources(content);

      expect(sources.map((s) => s.title), ['Flutter', 'Dart guides']);
      expect(sources.map((s) => s.url), [
        'https://flutter.dev',
        'https://dart.dev/guides',
      ]);
    });

    test('a bullet with no link is not a citation and is dropped', () {
      const content = '• Just a heading with no url\n• Real — https://x.com/a';
      final sources = parseWebSearchSources(content);
      expect(sources, hasLength(1));
      expect(sources.single.url, 'https://x.com/a');
    });

    test('a bare url with no title keeps the url as its label', () {
      final sources = parseWebSearchSources('• https://example.com/page');
      expect(sources.single.url, 'https://example.com/page');
      expect(sources.single.title, 'https://example.com/page');
    });

    test('the same url twice collapses to one, order preserved', () {
      const content =
          '• A — https://x.com/a\n• B — https://y.com/b\n• A again — https://x.com/a';
      final sources = parseWebSearchSources(content);
      expect(sources.map((s) => s.url), ['https://x.com/a', 'https://y.com/b']);
    });

    test('non-search tool output (no bullets) yields nothing', () {
      expect(parseWebSearchSources('Exit code: 0\nOutput: done'), isEmpty);
    });
  });

  group('WebSource', () {
    test('host drops the leading www. for a compact label', () {
      const source = WebSource(
        title: 'News',
        url: 'https://www.nytimes.com/2026/07/story',
      );
      expect(source.host, 'nytimes.com');
    });

    test('round-trips through json, dropping an entry with no url', () {
      const source = WebSource(title: 'Docs', url: 'https://dart.dev');
      final restored = WebSource.fromJson(source.toJson());
      expect(restored?.title, 'Docs');
      expect(restored?.url, 'https://dart.dev');
      expect(WebSource.fromJson({'title': 'x'}), isNull);
    });
  });
}
