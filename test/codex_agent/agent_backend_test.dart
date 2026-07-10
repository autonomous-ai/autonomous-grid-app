import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/codex_agent/logic/agent_backend.dart';
import 'package:grid_app/features/codex_agent/logic/agent_tool.dart';
import 'package:grid_app/infrastructure/state/chat_prefs_store.dart';

void main() {
  late Directory tmp;
  late File file;
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('grid_agent_backend_test');
    file = File('${tmp.path}/chat_prefs.json');
  });
  tearDown(() => tmp.delete(recursive: true));

  // A container whose prefs sit in a temp file and where every agent tool is
  // reported installed (or not, per [installed]).
  ProviderContainer container({bool installed = true}) {
    final c = ProviderContainer(
      overrides: [
        chatPrefsStoreProvider.overrideWithValue(ChatPrefsStore(file: file)),
        for (final tool in AgentTool.values)
          agentToolPathProvider(tool).overrideWith(
            (ref) => installed ? '/usr/local/bin/${tool.name}' : null,
          ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  test('starts Off when nothing was saved', () {
    expect(container().read(agentBackendProvider), AgentBackend.off);
  });

  test('setting a backend persists it for the next session', () {
    container().read(agentBackendProvider.notifier).set(AgentBackend.hermes);
    // A fresh container (new session) restores the saved backend.
    expect(container().read(agentBackendProvider), AgentBackend.hermes);
  });

  test('does not resume onto a backend whose tool was removed', () {
    ChatPrefsStore(file: file).save(const ChatPrefs(agent: 'hermes'));
    // Hermes is saved but no longer on PATH — fall back to Off rather than show
    // an armed picker that would fail every send.
    expect(
      container(installed: false).read(agentBackendProvider),
      AgentBackend.off,
    );
  });
}
