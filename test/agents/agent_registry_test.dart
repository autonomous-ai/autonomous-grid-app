import 'package:flutter/painting.dart' show decodeImageFromList;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agent/agent_registry.dart';
import 'package:grid_app/infrastructure/state/chat_prefs_store.dart';

void main() {
  // rootBundle needs the test binding; no widget is pumped (see §8 — logic and
  // asset checks only, never UI tests).
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every agent ships a mark the app can actually load and decode', () async {
    // A path missing from `pubspec.yaml`'s asset list, or misspelled, compiles
    // fine and throws only when a row paints. Loading each one here moves that
    // failure into CI, where adding an agent is a one-line diff and forgetting
    // the pubspec entry is the obvious way to get it wrong.
    for (final agent in kAgents) {
      final data = await rootBundle.load(agent.iconAsset);
      expect(
        data.lengthInBytes,
        greaterThan(0),
        reason: '${agent.id} has an empty icon at ${agent.iconAsset}',
      );
      // It must also decode: a truncated download, or an HTML error page saved
      // under a .png, passes a length check and still fails to paint.
      final image = await decodeImageFromList(data.buffer.asUint8List());
      expect(
        image.width,
        greaterThan(0),
        reason: '${agent.id} will not decode',
      );
    }
  });

  test('the chat-agent default is one of the agents on the list', () {
    // kDefaultChatAgent is what answers chats before the user picks — dropping
    // an agent from the registry must not leave chat pointed at one that no
    // longer exists.
    expect(kAgents, contains(kDefaultChatAgent));
  });

  test('the persistence default id resolves to the registry default', () {
    // ChatPrefs stores the agent as a bare id (it can't reach the registry). If
    // that constant drifts from kDefaultChatAgent, a fresh install would look up
    // an agent that isn't the intended default — or none at all.
    expect(agentById(ChatPrefs.defaultChatAgent), kDefaultChatAgent);
  });
}
