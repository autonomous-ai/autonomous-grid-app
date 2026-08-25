import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/app_update/logic/appcast_feed.dart';
import 'package:grid_app/infrastructure/state/update_dismiss_store.dart';

/// The feed as CI actually writes it, copied from the live
/// `appcast-arm64.xml` on 2026-08-25. Kept verbatim rather than tidied: the
/// point of these tests is that the app agrees with the file the release script
/// produces, and a cleaned-up sample would stop being evidence of that.
const String _liveFeed = '''
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Grid</title>
    <item>
      <title>Grid 0.3.59</title>
      <sparkle:shortVersionString>0.3.59</sparkle:shortVersionString>
      <sparkle:version>3059</sparkle:version>
      <pubDate>Mon, 24 Aug 2026 05:24:16 +0000</pubDate>
      <enclosure url="https://github.com/autonomous-ai/autonomous-grid-app/releases/download/v0.3.59/Grid-0.3.59-macOS-Apple-Silicon.dmg" sparkle:os="macos" sparkle:edSignature="qyhzefnooRsGd4a6cV8sb9geyxlL4vAa1yo0u3os0XoP3K33ojKdtSTIh4pR9fyWNtzVVKcoIhi6X1XhS/3RDg==" length="89512547" type="application/octet-stream" />
    </item>
  </channel>
</rss>
''';

/// Builds a feed with [items] between the channel tags.
String _feed(String items) =>
    '<?xml version="1.0" encoding="utf-8"?>'
    '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">'
    '<channel><title>Grid</title>$items</channel></rss>';

String _item({
  String? version,
  String? shortVersion = '1.0.0',
  String? url = 'https://example.test/Grid.dmg',
}) {
  final parts = [
    if (shortVersion != null)
      '<sparkle:shortVersionString>$shortVersion</sparkle:shortVersionString>',
    if (version != null) '<sparkle:version>$version</sparkle:version>',
    if (url != null) '<enclosure url="$url" sparkle:os="macos" length="1" />',
  ];
  return '<item>${parts.join()}</item>';
}

void main() {
  group('what the app offers a running build', () {
    test('the live feed offers its release to an older build', () {
      // A dev build stamps `0.2.0+1` from pubspec, so 1 is what this comparison
      // sees on every machine running the app from source.
      final release = updateFor(_liveFeed, installedBuild: 1);
      expect(release, isNotNull);
      expect(release!.shortVersion, '0.3.59');
      expect(release.build, 3059);
      expect(
        release.downloadUrl,
        endsWith('Grid-0.3.59-macOS-Apple-Silicon.dmg'),
      );
    });

    test('a build already at the feed version is offered nothing', () {
      // Equal is not newer. Getting this wrong puts a permanent banner in front
      // of everyone who is already up to date, which is worse than a missed
      // notice — Sparkle's own lane picks those up.
      expect(updateFor(_liveFeed, installedBuild: 3059), isNull);
    });

    test('a build ahead of the feed is offered nothing', () {
      // Happens for real: a machine on a build the feed has not caught up to,
      // and every dev build once the version is stamped by hand.
      expect(updateFor(_liveFeed, installedBuild: 9999), isNull);
    });

    test('the highest build wins, not the first one listed', () {
      // Sparkle's rule is "newest that applies". An appcast may list several
      // releases in any order, and taking document order would pin everyone to
      // whichever entry the script happened to write first.
      final feed = _feed(
        _item(version: '3040', shortVersion: '0.3.40') +
            _item(version: '3061', shortVersion: '0.3.61') +
            _item(version: '3055', shortVersion: '0.3.55'),
      );
      expect(updateFor(feed, installedBuild: 1)!.shortVersion, '0.3.61');
    });
  });

  group('what the app refuses to offer', () {
    test('a feed that is not XML offers nothing instead of throwing', () {
      // What a captive wifi portal serves in place of the file. It reaches this
      // function as a page of HTML, and it must not take the app down with it.
      expect(
        updateFor('<html>sign in to continue</html>', installedBuild: 1),
        isNull,
      );
      expect(updateFor('', installedBuild: 1), isNull);
    });

    test('an entry with no version number is dropped', () {
      // Unversioned means uncomparable. Offering it would mean guessing whether
      // it is newer than what is running.
      final feed = _feed(_item(version: null));
      expect(updateFor(feed, installedBuild: 1), isNull);
    });

    test('an entry with no download is dropped', () {
      // The signing step is skipped when SPARKLE_ED_PRIVATE_KEY is unset, so a
      // half-written feed is a real state, not a hypothetical one. A release
      // nobody can install is not worth a banner.
      final feed = _feed(_item(version: '3061', url: null));
      expect(updateFor(feed, installedBuild: 1), isNull);
    });

    test('one broken entry does not hide a good one beside it', () {
      final feed = _feed(
        _item(version: null) + _item(version: '3061', shortVersion: '0.3.61'),
      );
      expect(updateFor(feed, installedBuild: 1)!.build, 3061);
    });
  });

  group('reading a feed written slightly differently', () {
    test('the marketing version falls back to the build number', () {
      // A feed missing the display string is malformed, but everything needed
      // to install is still there — so the banner names the build rather than
      // withholding the update.
      final feed = _feed(_item(version: '3061', shortVersion: null));
      expect(updateFor(feed, installedBuild: 1)!.shortVersion, '3061');
    });

    test('a different namespace prefix still reads', () {
      // `sparkle:` is a prefix the generating script chose, not part of the
      // format. Matching the literal string would break the day someone renames
      // it in generate_appcast_macos.sh, and break silently.
      const feed =
          '<rss xmlns:sp="http://www.andymatuschak.org/xml-namespaces/sparkle">'
          '<channel><item>'
          '<sp:shortVersionString>0.4.0</sp:shortVersionString>'
          '<sp:version>4000</sp:version>'
          '<enclosure url="https://example.test/Grid.dmg" length="1" />'
          '</item></channel></rss>';
      expect(updateFor(feed, installedBuild: 1)!.shortVersion, '0.4.0');
    });

    test(
      'an element from another namespace is not mistaken for Sparkle\'s',
      () {
        // Guards the opposite mistake: matching by local name alone would read
        // any <version> in the document, including one a future feed adds under
        // its own namespace.
        const feed =
            '<rss xmlns:other="https://example.test/ns">'
            '<channel><item>'
            '<other:version>4000</other:version>'
            '<enclosure url="https://example.test/Grid.dmg" length="1" />'
            '</item></channel></rss>';
        expect(updateFor(feed, installedBuild: 1), isNull);
      },
    );
  });

  group('remembering that the banner was closed', () {
    late Directory dir;
    late File file;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('grid_update_dismiss');
      file = File('${dir.path}/update_dismissed.json');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('nothing dismissed before the file exists', () {
      expect(UpdateDismissStore(file: file).load(), isNull);
    });

    test('a closed banner is remembered across restarts', () {
      // The whole point of the file: closing the banner has to outlive the
      // session, or the next launch asks the same question again.
      UpdateDismissStore(file: file).save(3059);
      expect(UpdateDismissStore(file: file).load(), 3059);
    });

    test('a corrupt file reads as nothing dismissed', () {
      // Erring towards showing the banner again: the cost is one notice the
      // user has seen before, where the other direction hides an update for
      // good.
      file.writeAsStringSync('{ not json');
      expect(UpdateDismissStore(file: file).load(), isNull);
    });

    test('a file without a build number reads as nothing dismissed', () {
      file.writeAsStringSync('{"build": "3059"}');
      expect(UpdateDismissStore(file: file).load(), isNull);
    });
  });
}
