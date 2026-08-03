import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/connectors/logic/connector_catalog.dart';
import 'package:grid_app/features/connectors/logic/self_serve_catalog.dart';
import 'package:grid_app/features/connectors/logic/smithery_catalog.dart';
import 'package:grid_app/features/connectors/logic/smithery_server.dart';

/// The public directory as a source of connector rows.
///
/// The four things pinned here are the ones with a *silent* failure mode: a
/// paging default that never stops, a sort that mutates the list it was given,
/// a precedence rule that would let a community row shadow the gateway's, and
/// the filter/search exclusivity that would otherwise answer the wrong question.
void main() {
  SmitheryServer server(
    String name, {
    bool remote = true,
    bool deployed = true,
    bool verified = false,
    int useCount = 0,
    String display = '',
  }) => SmitheryServer(
    qualifiedName: name,
    displayName: display.isEmpty ? name : display,
    remote: remote,
    deployed: deployed,
    verified: verified,
    useCount: useCount,
  );

  group('parsing', () {
    test('reads the quality fields the list is filtered and sorted on', () {
      final parsed = SmitheryServer.fromJson({
        'qualifiedName': 'exa',
        'displayName': 'Exa Search',
        'remote': true,
        'isDeployed': true,
        'verified': true,
        'useCount': 12491,
        'bySmithery': true,
      });

      expect(parsed!.verified, isTrue);
      expect(parsed.useCount, 12491);
      expect(parsed.bySmithery, isTrue);
    });

    test('a count that arrives as a double still counts', () {
      // JSON has one number type. Read as `int` this would throw or, worse,
      // fall to zero and sort to the bottom of every "Most used" list.
      final parsed = SmitheryServer.fromJson({
        'qualifiedName': 'x',
        'displayName': 'X',
        'useCount': 1200.0,
      });

      expect(parsed!.useCount, 1200);
    });

    test('a missing pagination block means "no more", not endless', () {
      // The sharpest default on this path: one step wrong and Load more never
      // switches off, asking for page 2 of a directory that has one page.
      final page = SmitheryPage.fromJson({
        'servers': [
          {
            'qualifiedName': 'a',
            'displayName': 'A',
            'remote': true,
            'isDeployed': true,
          },
        ],
      });

      expect(page!.hasMore, isFalse);
    });

    test('a malformed row drops itself and the page still renders', () {
      final page = SmitheryPage.fromJson({
        'servers': [
          {'displayName': 'no qualified name'},
          {
            'qualifiedName': 'good',
            'displayName': 'Good',
            'remote': true,
            'isDeployed': true,
          },
        ],
        'pagination': {'currentPage': 1, 'totalPages': 1, 'totalCount': 2},
      });

      expect(page!.servers.map((s) => s.qualifiedName), ['good']);
    });

    test('a row that cannot be connected never reaches the list', () {
      // Remote-capable but not currently hosted: its gateway URL 404s, so a
      // Connect button on it could only fail on press.
      final page = SmitheryPage.fromJson({
        'servers': [
          {
            'qualifiedName': 'cold',
            'displayName': 'Cold',
            'remote': true,
            'isDeployed': false,
          },
        ],
        'pagination': {'currentPage': 1, 'totalPages': 1},
      });

      expect(page!.servers, isEmpty);
    });
  });

  group('sort', () {
    final rows = [
      server('b', display: 'Beta', useCount: 10),
      server('a', display: 'Alpha', useCount: 90),
    ];

    test('relevance keeps the registry\'s own order', () {
      expect(
        SmitheryServerSort.relevance.apply(rows).map((s) => s.displayName),
        ['Beta', 'Alpha'],
      );
    });

    test('most used and name reorder', () {
      expect(
        SmitheryServerSort.mostUsed.apply(rows).map((s) => s.displayName),
        ['Alpha', 'Beta'],
      );
      expect(SmitheryServerSort.name.apply(rows).map((s) => s.displayName), [
        'Alpha',
        'Beta',
      ]);
    });

    test('sorting never mutates the list it was given', () {
      // The caller's list is controller state. An in-place sort would reorder
      // the fetched rows, and switching back to Relevance could not restore
      // what the registry actually sent.
      final original = [...rows];
      SmitheryServerSort.mostUsed.apply(rows);
      expect(
        rows.map((s) => s.displayName),
        original.map((s) => s.displayName),
      );
    });
  });

  group('as catalog rows', () {
    test('a directory row carries the address and signs itself in', () {
      final entry = smitheryCatalogEntry(
        server('vercel/grep', display: 'Grep'),
      );

      expect(entry.code, 'vercel-grep', reason: 'a / in a config key quotes');
      expect(entry.mcpUrl, 'https://server.smithery.ai/vercel/grep/mcp');
      expect(entry.authMethod, ConnectorAuthMethod.dcr);
      expect(entry.canConnectFromApp, isTrue);
    });

    test('it claims nothing about an account the gateway never saw', () {
      final entry = smitheryCatalogEntry(server('exa'));

      // `linkedAtServer: true` here would put "connected to your account, but
      // not on this computer" under a row no account was ever linked to.
      expect(entry.linkedAtServer, isFalse);
      expect(entry.installed, isFalse);
      expect(entry.accountName, isEmpty);
      expect(entry.canRefresh, isFalse);
    });
  });

  group('precedence in the merged catalog', () {
    ConnectorCatalogEntry entry(String code, String label) =>
        ConnectorCatalogEntry(
          id: code,
          code: code,
          label: label,
          description: '',
        );

    test('the gateway wins a code clash against the directory', () {
      final merged = mergeCatalog(
        gateway: [entry('notion', 'Notion (gateway)')],
        selfServe: const [],
        directory: [entry('notion', 'Notion (community)')],
      );

      expect(merged.length, 1);
      expect(merged.single.label, 'Notion (gateway)');
    });

    test('a bundled row also outranks the directory', () {
      final merged = mergeCatalog(
        gateway: const [],
        selfServe: [entry('stripe', 'Stripe (bundled)')],
        directory: [entry('stripe', 'Stripe (community)')],
      );

      expect(merged.single.label, 'Stripe (bundled)');
    });

    test('directory rows the other two do not claim are kept', () {
      final merged = mergeCatalog(
        gateway: [entry('github', 'GitHub')],
        selfServe: [entry('stripe', 'Stripe')],
        directory: [entry('exa', 'Exa'), entry('github', 'GitHub (community)')],
      );

      expect(merged.map((e) => e.code).toSet(), {'github', 'stripe', 'exa'});
      expect(merged.firstWhere((e) => e.code == 'github').label, 'GitHub');
    });

    test('directory rows keep the order they were given', () {
      // The bug this pins: `mergeCatalog` used to run everything through
      // `sortCatalog`, which alphabetised four thousand community servers —
      // putting `agentai` above Brave Search and silently undoing whatever the
      // Sort control had just done. The sort ran; this threw it away.
      final merged = mergeCatalog(
        gateway: const [],
        selfServe: const [],
        directory: [entry('zebra', 'Zebra'), entry('alpha', 'Alpha')],
      );

      expect(merged.map((e) => e.code), ['zebra', 'alpha']);
    });

    test('curated rows are still alphabetical, and still come first', () {
      final merged = mergeCatalog(
        gateway: [entry('zulu', 'Zulu'), entry('alfa', 'Alfa')],
        selfServe: const [],
        directory: [entry('mike', 'Mike')],
      );

      // Forty curated entries somebody chose: a name is how you find one.
      expect(merged.map((e) => e.code), ['alfa', 'zulu', 'mike']);
    });

    test('an absent directory leaves the old two-source behaviour', () {
      // The whole feature has to be removable without touching this call.
      final merged = mergeCatalog(
        gateway: [entry('github', 'GitHub')],
        selfServe: [entry('stripe', 'Stripe')],
      );

      expect(merged.map((e) => e.code), ['github', 'stripe']);
    });
  });
}
