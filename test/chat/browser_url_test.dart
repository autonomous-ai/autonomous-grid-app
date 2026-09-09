import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/browser/logic/browser_url.dart';

void main() {
  group('what the address bar does with what was typed', () {
    test('a bare host is opened, not searched for', () {
      expect(addressBarUrl('example.com'), 'https://example.com');
      expect(addressBarUrl('foo.bar/path'), 'https://foo.bar/path');
    });

    test('a host with a port and a path is still a host', () {
      // The pattern this was ported from stops at the TLD, so `:8080/x` fell
      // through to a search — an ordinary dev address that would have been
      // typed straight into a search engine.
      expect(
        addressBarUrl('example.com:8080/admin'),
        'https://example.com:8080/admin',
      );
    });

    test('localhost keeps its port instead of reading as a scheme', () {
      // `localhost:3000` parses as the scheme `localhost` — the reason this
      // case is matched before anything is parsed at all.
      expect(addressBarUrl('localhost:3000'), 'http://localhost:3000');
      expect(addressBarUrl('127.0.0.1:8080/x'), 'http://127.0.0.1:8080/x');
    });

    test('words are searched for, and so is anything host-shaped but not', () {
      expect(
        addressBarUrl('react hooks'),
        'https://www.google.com/search?q=react+hooks',
      );
      // A version number is the case a dotted-input-is-a-host rule gets wrong:
      // it has a dot, so it navigated to `https://3.14`.
      expect(addressBarUrl('3.14'), 'https://www.google.com/search?q=3.14');
    });

    test('the search goes to whichever engine the user chose', () {
      expect(
        addressBarUrl('react hooks', engine: BrowserSearchEngine.duckDuckGo),
        'https://duckduckgo.com/?q=react+hooks',
      );
      expect(BrowserSearchEngine.byId('bing'), BrowserSearchEngine.bing);
      // An id from an older build, or one edited by hand, must not leave the
      // address bar with nowhere to search.
      expect(BrowserSearchEngine.byId('altavista'), BrowserSearchEngine.google);
    });

    test(
      'a path the user typed opens as a file, an empty bar does nothing',
      () {
        expect(addressBarUrl('/tmp/report.html'), 'file:///tmp/report.html');
        expect(addressBarUrl('   '), isNull);
      },
    );

    test('a scheme this tab cannot draw is refused rather than searched', () {
      // Null is what makes the tab say so. Searching for "mailto:a@b.com"
      // would look like the app ignoring what was asked for.
      expect(addressBarUrl('mailto:a@b.com'), isNull);
      expect(addressBarUrl('javascript:alert(1)'), isNull);
    });
  });

  group('what a page is allowed to navigate itself to', () {
    test('ordinary web navigation is allowed', () {
      expect(
        classifyPageNavigation('https://example.com'),
        PageNavigation.allow,
      );
      expect(classifyPageNavigation('/about'), PageNavigation.allow);
    });

    test('a page may not send this tab at the disk or at a script', () {
      // Typing a path is the user reaching for their own file; a *page* asking
      // for one is a site reading what the user has.
      expect(
        classifyPageNavigation('file:///etc/passwd'),
        PageNavigation.block,
      );
      expect(
        classifyPageNavigation('javascript:alert(1)'),
        PageNavigation.block,
      );
      expect(classifyPageNavigation(null), PageNavigation.block);
    });

    test('a link for another app is handed to the system', () {
      expect(
        classifyPageNavigation('mailto:someone@example.com'),
        PageNavigation.openInSystemBrowser,
      );
    });
  });

  group('what a browser tab is called', () {
    test('the page names it, and the host names it when the page will not', () {
      expect(
        browserTabTitle(
          title: 'Example Domain',
          url: 'https://example.com/',
          fallback: 'Browser',
        ),
        'Example Domain',
      );
      expect(
        browserTabTitle(title: '', url: 'https://example.com/x', fallback: 'B'),
        'example.com',
      );
    });

    test('a tab that has been nowhere keeps the name it was opened under', () {
      // Otherwise a second empty Browser tab takes the first one's name and the
      // strip has two rows nobody can tell apart.
      expect(
        browserTabTitle(title: '', url: '', fallback: 'Browser 2'),
        'Browser 2',
      );
    });
  });
}
