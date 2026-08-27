import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/grid_web_skill.dart';
import 'package:grid_app/infrastructure/cli/host_environment.dart';

/// One recorded request, so a test can assert what the script actually sent.
class _Seen {
  String? path;
  String? authorization;
  Map<String, dynamic>? body;
}

/// A loopback stand-in for this grid's relay.
///
/// The script is now the layer that authenticates, calls the network, maps
/// refusals to sentences and formats output — none of which a test that asserts
/// on the script's *text* can see. So it is run, against this.
class _Relay {
  _Relay(this._server, this.seen);

  final HttpServer _server;
  final _Seen seen;

  String get url => 'http://127.0.0.1:${_server.port}/relay/v1';

  static Future<_Relay> serving({
    int status = 200,
    Object? payload,
    String? raw,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final seen = _Seen();
    server.listen((request) async {
      seen.path = request.uri.path;
      seen.authorization = request.headers.value('authorization');
      final text = await utf8.decoder.bind(request).join();
      seen.body = text.isEmpty
          ? null
          : jsonDecode(text) as Map<String, dynamic>;
      request.response.statusCode = status;
      request.response.headers.contentType = ContentType.json;
      request.response.write(raw ?? jsonEncode(payload ?? const {'results': []}));
      await request.response.close();
    });
    return _Relay(server, seen);
  }

  Future<void> close() => _server.close(force: true);
}

/// What the app writes to disk as `search.py`, byte for byte.
late final Directory _scripts;
late final String _searchScript;
late final String _python;

/// Async on purpose. `Process.runSync` blocks this isolate, and the stand-in
/// relay is served from it — so the script would post into a server that cannot
/// answer until the script has given up, and every test would fail as a
/// timeout. The deadlock is silent: the message is the script's own
/// "couldn't reach the grid", which is exactly what a real offline machine says.
Future<ProcessResult> _run(
  List<String> args, {
  String? relayUrl,
  String? token = 'per-grid-token',
  Map<String, String> extra = const {},
}) => Process.run(_python, [
  _searchScript,
  ...args,
], environment: {
  HostEnvironment.relayUrlVar: ?relayUrl,
  HostEnvironment.relayTokenVar: ?token,
  ...extra,
});

void main() {
  setUpAll(() {
    // Named rather than skipped when it is missing. The guide tells an agent to
    // run `python3 <path>` with no package runner in front of it, so a machine
    // without one cannot search — and a suite that skipped here would be a
    // suite that passes by never running, on exactly the layer this file exists
    // to cover.
    final python = HostEnvironment.findExecutable('python3');
    expect(
      python,
      isNotNull,
      reason: 'python3 is not on PATH — the search script cannot be exercised',
    );
    _python = python!;
    _scripts = Directory.systemTemp.createTempSync('grid-web-search');
    final file = File('${_scripts.path}/search.py');
    file.writeAsStringSync(kGridWebSearchScript);
    _searchScript = file.path;
  });

  tearDownAll(() => _scripts.deleteSync(recursive: true));

  test('a search prints title, URL and excerpt with a blank line between', () async {
    final relay = await _Relay.serving(
      payload: {
        'results': [
          {
            'title': 'Titan arum blooms',
            'url': 'https://example.invalid/titan',
            'excerpt': 'It opened on Tuesday.',
          },
          {
            'title': 'Second',
            'url': 'https://example.invalid/2',
            'excerpt': 'Another one.',
          },
        ],
      },
    );
    addTearDown(relay.close);

    final result = await _run(['titan arum'], relayUrl: relay.url);

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(
      result.stdout,
      'Titan arum blooms\n'
      'https://example.invalid/titan\n'
      'It opened on Tuesday.\n'
      '\n'
      'Second\n'
      'https://example.invalid/2\n'
      'Another one.\n'
      '\n',
    );
  });

  test('the query, the count and the grid credential are what it sends', () async {
    final relay = await _Relay.serving();
    addTearDown(relay.close);

    final result = await _run(['titan arum', '--max', '3'], relayUrl: relay.url);

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(relay.seen.path, '/relay/v1/web/search');
    expect(relay.seen.authorization, 'Bearer per-grid-token');
    expect(relay.seen.body, {'query': 'titan arum', 'num_results': 3});
  });

  test('it never presents a vendor credential from its own environment', () async {
    // A script reading `ANTHROPIC_AUTH_TOKEN` or `GRID_APP_API_KEY` is a
    // credential-leak shape, not untidiness: the app's own process can be
    // carrying an `ANTHROPIC_*` a developer exported, and a script that read it
    // would post a person's real vendor key to a relay.
    final relay = await _Relay.serving();
    addTearDown(relay.close);

    final result = await _run(
      ['titan arum'],
      relayUrl: relay.url,
      extra: const {
        'ANTHROPIC_AUTH_TOKEN': 'sk-ant-a-persons-real-key',
        'ANTHROPIC_API_KEY': 'sk-ant-a-persons-real-key',
        'GRID_APP_API_KEY': 'grid-app-key',
      },
    );

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(relay.seen.authorization, 'Bearer per-grid-token');
    expect(relay.seen.body.toString(), isNot(contains('sk-ant-')));
  });

  test('nothing found is an ordinary answer, not a failure', () async {
    final relay = await _Relay.serving(payload: const {'results': []});
    addTearDown(relay.close);

    final result = await _run(['titan arum'], relayUrl: relay.url);

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, 'No results.\n');
    expect(result.stderr, isEmpty);
  });

  // ── the refusals, which are the paths a text assertion can never see ──

  test('a caller with no grid is told it needs one', () async {
    final result = await _run(['titan arum'], relayUrl: null, token: null);

    expect(result.exitCode, 2);
    expect(result.stderr, contains('needs a grid'));
    expect(result.stdout, isEmpty);
  });

  test('half a credential is treated as no credential', () async {
    // A URL with no token would post unauthenticated and be refused at the far
    // end, which reads as a broken grid rather than as one not picked yet.
    final relay = await _Relay.serving();
    addTearDown(relay.close);

    final result = await _run(['titan arum'], relayUrl: relay.url, token: null);

    expect(result.exitCode, 2);
    expect(result.stderr, contains('needs a grid'));
    expect(relay.seen.path, isNull, reason: 'it posted without a credential');
  });

  test('a relay too old to serve the route says so in one sentence', () async {
    final relay = await _Relay.serving(status: 404, raw: 'Not Found');
    addTearDown(relay.close);

    final result = await _run(['titan arum'], relayUrl: relay.url);

    expect(result.exitCode, 2);
    expect(result.stderr, contains('/web/search'));
    expect(result.stderr, contains('update it'));
    expect(result.stderr, isNot(contains('Traceback')));
  });

  test('being rate-limited is one sentence and never an empty result', () async {
    const sentence =
        'Web search is busy right now. Wait a few seconds and try once, rather than retrying repeatedly.';
    final relay = await _Relay.serving(
      status: 429,
      payload: const {'detail': sentence},
    );
    addTearDown(relay.close);

    final result = await _run(['titan arum'], relayUrl: relay.url);

    // Not exit 0, and nothing on stdout: an agent that read this as "I found
    // nothing" would report a fact that is not true.
    expect(result.exitCode, 1);
    expect(result.stdout, isEmpty);
    expect(result.stderr, contains(sentence));
  });

  test('a spent allowance says it is a limit and when it lifts', () async {
    // Public-repo ADR 0036 D-d. It shares 429 with the vendor being busy, and the two want
    // opposite things from an agent: one lifts in seconds, the other in hours. Exit 2, so the
    // guide's "exit 1 is worth one more try" never applies to it.
    const sentence =
        "You have used this account's daily web-search allowance of 250 searches. "
        'It returns in about 18 hours. This is a limit, not a failure — do not retry until then.';
    final relay = await _Relay.serving(
      status: 429,
      payload: const {
        'detail': sentence,
        'code': 'web_search_allowance_exhausted',
        'retry_after_seconds': 64800,
      },
    );
    addTearDown(relay.close);

    final result = await _run(['titan arum'], relayUrl: relay.url);

    expect(result.exitCode, 2);
    expect(result.stdout, isEmpty);
    expect(result.stderr, contains(sentence));
  });

  test('an allowance refusal is told from the vendor being busy by its code', () async {
    // The positive control for the pair: the two differ in the body alone, so a script that keyed
    // on the status would give both the same exit code and one of the two answers would be wrong.
    final busy = await _Relay.serving(
      status: 429,
      payload: const {'detail': 'Web search is busy right now.'},
    );
    addTearDown(busy.close);
    final spent = await _Relay.serving(
      status: 429,
      payload: const {
        'detail': "You have used this account's daily web-search allowance.",
        'code': 'web_search_allowance_exhausted',
      },
    );
    addTearDown(spent.close);

    final busyRun = await _run(['titan arum'], relayUrl: busy.url);
    final spentRun = await _run(['titan arum'], relayUrl: spent.url);

    expect(busyRun.exitCode, 1);
    expect(spentRun.exitCode, 2);
  });

  test('a relay too old to carry the code still shows the sentence', () async {
    // The rollout gap: control plane, then relay, then app. A relay in between forwards `detail`
    // and drops `code`, so the person still reads why they were refused — at exit 1, which is the
    // degrade this ordering accepts and the reason the relay ships before this script does.
    final relay = await _Relay.serving(
      status: 429,
      payload: const {'detail': 'You have used this account\'s daily web-search allowance.'},
    );
    addTearDown(relay.close);

    final result = await _run(['titan arum'], relayUrl: relay.url);

    expect(result.exitCode, 1);
    expect(result.stderr, contains('allowance'));
  });

  test('a grid that cannot search at all is exit 2, not exit 1', () async {
    final relay = await _Relay.serving(
      status: 503,
      payload: const {'detail': 'This grid is not connected to a control plane.'},
    );
    addTearDown(relay.close);

    final result = await _run(['titan arum'], relayUrl: relay.url);

    expect(result.exitCode, 2);
    expect(result.stderr, contains('control plane'));
  });

  test('a refused credential sends the person to Grid, not to a retry', () async {
    final relay = await _Relay.serving(
      status: 401,
      payload: const {'detail': 'Grid token is for another network'},
    );
    addTearDown(relay.close);

    final result = await _run(['titan arum'], relayUrl: relay.url);

    expect(result.exitCode, 2);
    expect(result.stderr, contains('Grid'));
    expect(result.stderr, isNot(contains('Traceback')));
  });

  test('an unreachable grid is a sentence, not a stack trace', () async {
    // Nothing is listening on this port — the shape a laptop that went offline
    // mid-turn produces.
    final result = await _run(['titan arum'], relayUrl: 'http://127.0.0.1:1/relay/v1');

    expect(result.exitCode, 1);
    expect(result.stderr, contains("couldn't reach the grid"));
    expect(result.stderr, isNot(contains('Traceback')));
  });

  test('an answer that is not a search result is a failure, not zero results', () async {
    final relay = await _Relay.serving(raw: '<html>a proxy login page</html>');
    addTearDown(relay.close);

    final result = await _run(['titan arum'], relayUrl: relay.url);

    expect(result.exitCode, 1);
    expect(result.stdout, isEmpty);
    expect(result.stderr, contains("isn't a search result"));
  });

  test('no package runner and no DuckDuckGo are left in the script', () {
    // The one honest text assertion in this file, and it is about *absence*:
    // running the script can show that it works, never that the old backend is
    // gone from it.
    expect(kGridWebSearchScript, isNot(contains('ddgs')));
    expect(kGridWebSearchScript, isNot(contains('uv run')));
    expect(kGridWebSearchScript, isNot(contains('--with')));
  });
}
