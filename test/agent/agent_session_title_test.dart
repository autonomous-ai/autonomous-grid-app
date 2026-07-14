import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/logic/agent_session_title.dart';
import 'package:grid_app/features/agent/logic/hermes_tool.dart';
import 'package:grid_app/infrastructure/cli/hermes_session_service.dart';

/// A session store that hands back [_titles] one look-up at a time — the agent
/// writes the name a beat after it answers, so the early looks come up empty.
class _FakeSessions implements HermesSessionService {
  _FakeSessions(this._titles);

  final List<String?> _titles;
  final asked = <String>[];

  @override
  Future<String?> title(String sessionId) async {
    asked.add(sessionId);
    return asked.length <= _titles.length ? _titles[asked.length - 1] : null;
  }
}

ProviderContainer _container(HermesSessionService? sessions) {
  final container = ProviderContainer(
    overrides: [
      hermesSessionServiceProvider.overrideWithValue(sessions),
      // Don't sit through the real waits.
      agentTitleRetriesProvider.overrideWithValue(const [
        Duration.zero,
        Duration.zero,
        Duration.zero,
      ]),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('keeps asking until the agent has named the session', () async {
    final sessions = _FakeSessions([null, null, 'Kiểm tra thư mục dự án']);
    final container = _container(sessions);

    final title = await container
        .read(agentSessionTitleProvider)
        .waitFor('sess-1');

    expect(title, 'Kiểm tra thư mục dự án');
    expect(sessions.asked, ['sess-1', 'sess-1', 'sess-1']);
  });

  test('gives up quietly when the session never gets a name — the chat keeps '
      'the one it has', () async {
    final container = _container(_FakeSessions(const []));

    expect(
      await container.read(agentSessionTitleProvider).waitFor('sess-1'),
      isNull,
    );
  });

  test('no agent installed, no name to ask for', () async {
    final container = ProviderContainer(
      overrides: [hermesPathProvider.overrideWithValue(null)],
    );
    addTearDown(container.dispose);

    expect(container.read(hermesSessionServiceProvider), isNull);
    expect(
      await container.read(agentSessionTitleProvider).waitFor('sess-1'),
      isNull,
    );
  });

  group('parseSessionTitle', () {
    test('reads the name off the session record', () {
      expect(
        parseSessionTitle(
          '{"id": "sess-1", "source": "acp", '
          '"title": "Kiểm tra thư mục dự án Flutter Grid"}',
        ),
        'Kiểm tra thư mục dự án Flutter Grid',
      );
    });

    test('an unnamed session reads as no name, not an empty one', () {
      expect(parseSessionTitle('{"id": "sess-1", "title": null}'), isNull);
      expect(parseSessionTitle('{"id": "sess-1", "title": "  "}'), isNull);
      expect(parseSessionTitle('{"id": "sess-1"}'), isNull);
    });

    test('a line that is not a session record reads as no name', () {
      expect(parseSessionTitle('not json'), isNull);
      expect(parseSessionTitle('[1, 2]'), isNull);
      expect(parseSessionTitle(''), isNull);
    });
  });
}
