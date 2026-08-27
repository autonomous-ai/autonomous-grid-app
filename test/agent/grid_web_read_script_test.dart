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
/// The read script authenticates, calls the network and maps refusals to
/// sentences — none of which a test that asserts on its *text* can see. So it
/// is run, against this. Same seam as `grid_web_search_script_test.dart`.
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

/// One page as the control plane reports it, through the relay untouched.
Map<String, Object> _page({
  String url = 'https://example.invalid/article',
  String title = 'An article',
  String text = 'The article body.',
  String status = 'success',
  String error = '',
}) => {
  'url': url,
  'title': title,
  'text': text,
  'status': status,
  'error': error,
};

late final Directory _scripts;
late final String _readScript;
late final String _python;

/// Async on purpose — `Process.runSync` deadlocks against a server served from
/// this same isolate, and the symptom is the script's own "couldn't reach the
/// grid", which is exactly what a real offline machine says.
Future<ProcessResult> _run(
  List<String> args, {
  String? relayUrl,
  String? token = 'per-grid-token',
  Map<String, String> extra = const {},
}) => Process.run(_python, [
  _readScript,
  ...args,
], environment: {
  HostEnvironment.relayUrlVar: ?relayUrl,
  HostEnvironment.relayTokenVar: ?token,
  ...extra,
});

void main() {
  setUpAll(() {
    // Named rather than skipped when it is missing: the guide tells an agent to
    // run `python3 <path>` with nothing in front of it, so a machine without one
    // cannot read a page — and a suite that skipped here would pass by never
    // running, on the layer this file exists to cover.
    final python = HostEnvironment.findExecutable('python3');
    expect(
      python,
      isNotNull,
      reason: 'python3 is not on PATH — the read script cannot be exercised',
    );
    _python = python!;
    _scripts = Directory.systemTemp.createTempSync('grid-web-read');
    final file = File('${_scripts.path}/read.py');
    file.writeAsStringSync(kGridWebReadScript);
    _readScript = file.path;
  });

  tearDownAll(() => _scripts.deleteSync(recursive: true));

  test('reading an article prints its main text', () async {
    final relay = await _Relay.serving(
      payload: {
        'results': [_page(text: 'The titan arum opened on Tuesday.')],
      },
    );
    addTearDown(relay.close);

    final result = await _run(
      ['https://example.invalid/article'],
      relayUrl: relay.url,
    );

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, 'The titan arum opened on Tuesday.\n');
  });

  test('the url and the grid credential are what it sends', () async {
    final relay = await _Relay.serving(payload: {
      'results': [_page()],
    });
    addTearDown(relay.close);

    final result = await _run(
      ['https://example.invalid/article'],
      relayUrl: relay.url,
    );

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(relay.seen.path, '/relay/v1/web/contents');
    expect(relay.seen.authorization, 'Bearer per-grid-token');
    // Equality: the point is everything that is NOT sent. `text` is the
    // control plane's to decide, and a knob added here would cost the operator
    // more per call at the vendor.
    expect(relay.seen.body, {
      'urls': ['https://example.invalid/article'],
    });
  });

  test('a page that builds itself with JavaScript is one command, not three', () async {
    // The whole of D-g from the agent's side: what used to need a second
    // script, a ~170 MB browser download and an exit code asking for one is now
    // the same single call, because the vendor's contents endpoint renders.
    final relay = await _Relay.serving(
      payload: {
        'results': [_page(text: 'Content that only exists after JavaScript ran.')],
      },
    );
    addTearDown(relay.close);

    final result = await _run(
      ['https://example.invalid/app'],
      relayUrl: relay.url,
    );

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, contains('after JavaScript ran'));
    expect(result.stderr, isEmpty);
  });

  test('long text is truncated at --max-chars and says so', () async {
    final relay = await _Relay.serving(
      payload: {
        'results': [_page(text: 'x' * 5000)],
      },
    );
    addTearDown(relay.close);

    final result = await _run(
      ['https://example.invalid/long', '--max-chars', '500'],
      relayUrl: relay.url,
    );

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, contains('truncated'));
    expect((result.stdout as String).length, lessThan(1000));
  });

  // ── a page that refused is not a page with nothing on it ──

  test('a page the vendor could not fetch is a failure, never "nothing there"', () async {
    // The false negative this distinction exists to prevent: an agent told
    // "there is nothing on that page" about a page that turned it away reports
    // a fact that is not true, in a confident voice.
    final relay = await _Relay.serving(
      payload: {
        'results': [
          _page(text: '', status: 'error', error: 'CRAWL_NOT_FOUND'),
        ],
      },
    );
    addTearDown(relay.close);

    final result = await _run(
      ['https://example.invalid/gone'],
      relayUrl: relay.url,
    );

    expect(result.exitCode, 1);
    expect(result.stdout, isEmpty);
    expect(result.stderr, contains("couldn't read the page"));
    expect(result.stderr, contains('CRAWL_NOT_FOUND'));
  });

  test('a page that really had nothing on it is an ordinary answer', () async {
    final relay = await _Relay.serving(
      payload: {
        'results': [_page(text: '')],
      },
    );
    addTearDown(relay.close);

    final result = await _run(
      ['https://example.invalid/empty'],
      relayUrl: relay.url,
    );

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, contains('No readable text'));
    expect(result.stderr, isEmpty);
  });

  test('it never presents a vendor credential from its own environment', () async {
    final relay = await _Relay.serving(payload: {
      'results': [_page()],
    });
    addTearDown(relay.close);

    final result = await _run(
      ['https://example.invalid/article'],
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

  // ── the refusals ──

  test('a caller with no grid is told it needs one', () async {
    final result = await _run(
      ['https://example.invalid/article'],
      relayUrl: null,
      token: null,
    );

    expect(result.exitCode, 2);
    expect(result.stderr, contains('needs a grid'));
    expect(result.stdout, isEmpty);
  });

  test('half a credential is treated as no credential', () async {
    final relay = await _Relay.serving();
    addTearDown(relay.close);

    final result = await _run(
      ['https://example.invalid/article'],
      relayUrl: relay.url,
      token: null,
    );

    expect(result.exitCode, 2);
    expect(result.stderr, contains('needs a grid'));
    expect(relay.seen.path, isNull, reason: 'it posted without a credential');
  });

  test('a relay too old to serve the route says so in one sentence', () async {
    final relay = await _Relay.serving(status: 404, raw: 'Not Found');
    addTearDown(relay.close);

    final result = await _run(
      ['https://example.invalid/article'],
      relayUrl: relay.url,
    );

    expect(result.exitCode, 2);
    expect(result.stderr, contains('/web/contents'));
    expect(result.stderr, contains('update it'));
    expect(result.stderr, isNot(contains('Traceback')));
  });

  test('a refused credential sends the person to Grid, not to a retry', () async {
    final relay = await _Relay.serving(
      status: 401,
      payload: const {'detail': 'Grid token is for another network'},
    );
    addTearDown(relay.close);

    final result = await _run(
      ['https://example.invalid/article'],
      relayUrl: relay.url,
    );

    expect(result.exitCode, 2);
    expect(result.stderr, contains('Grid'));
    expect(result.stderr, isNot(contains('Traceback')));
  });

  test('being rate-limited is one sentence and never an empty page', () async {
    const sentence =
        'Web search is busy right now. Wait a few seconds and try once, rather than retrying repeatedly.';
    final relay = await _Relay.serving(
      status: 429,
      payload: const {'detail': sentence},
    );
    addTearDown(relay.close);

    final result = await _run(
      ['https://example.invalid/article'],
      relayUrl: relay.url,
    );

    expect(result.exitCode, 1);
    expect(result.stdout, isEmpty);
    expect(result.stderr, contains(sentence));
  });

  test('a spent allowance is exit 2, told from a busy vendor by its code', () async {
    // Reading spends the same per-account allowance as searching, so it meets
    // the same refusal — and the two 429s want opposite things from an agent.
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

    final busyRun = await _run(
      ['https://example.invalid/article'],
      relayUrl: busy.url,
    );
    final spentRun = await _run(
      ['https://example.invalid/article'],
      relayUrl: spent.url,
    );

    expect(busyRun.exitCode, 1);
    expect(spentRun.exitCode, 2);
    expect(spentRun.stderr, contains('allowance'));
  });

  test('a grid that cannot reach a control plane is exit 2, not exit 1', () async {
    final relay = await _Relay.serving(
      status: 503,
      payload: const {'detail': 'This grid is not connected to a control plane.'},
    );
    addTearDown(relay.close);

    final result = await _run(
      ['https://example.invalid/article'],
      relayUrl: relay.url,
    );

    expect(result.exitCode, 2);
    expect(result.stderr, contains('control plane'));
  });

  test('an unreachable grid is a sentence, not a stack trace', () async {
    final result = await _run(
      ['https://example.invalid/article'],
      relayUrl: 'http://127.0.0.1:1/relay/v1',
    );

    expect(result.exitCode, 1);
    expect(result.stderr, contains("couldn't reach the grid"));
    expect(result.stderr, isNot(contains('Traceback')));
  });

  test('an answer that is not a page is a failure, not an empty page', () async {
    final relay = await _Relay.serving(raw: '<html>a proxy login page</html>');
    addTearDown(relay.close);

    final result = await _run(
      ['https://example.invalid/article'],
      relayUrl: relay.url,
    );

    expect(result.exitCode, 1);
    expect(result.stdout, isEmpty);
    expect(result.stderr, isNot(contains('Traceback')));
  });

  test('a relay that answered about no page at all is a failure', () async {
    // Not "nothing there": the control plane answers one entry per URL asked
    // for, so an empty list is a broken seam and never a blank page.
    final relay = await _Relay.serving(payload: const {'results': []});
    addTearDown(relay.close);

    final result = await _run(
      ['https://example.invalid/article'],
      relayUrl: relay.url,
    );

    expect(result.exitCode, 1);
    expect(result.stdout, isEmpty);
  });

  test('both remaining scripts are standard library only', () {
    // Asserted, not assumed — this is what removes the package runner from both
    // guides, and it is a property of the script text that running it cannot
    // show. `trafilatura` and `playwright` are the two backends that are gone.
    for (final script in [kGridWebSearchScript, kGridWebReadScript]) {
      expect(script, isNot(contains('uv run')));
      expect(script, isNot(contains('--with')));
      expect(script, isNot(contains('trafilatura')));
      expect(script, isNot(contains('playwright')));
      expect(script, isNot(contains('ddgs')));
    }
  });
}
