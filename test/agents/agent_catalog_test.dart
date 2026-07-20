import 'package:flutter/painting.dart' show decodeImageFromList;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_catalog.dart';

void main() {
  // rootBundle needs the test binding; no widget is pumped (see §8 — logic and
  // asset checks only, never UI tests).
  TestWidgetsFlutterBinding.ensureInitialized();

  test('every agent ships a mark the app can actually load and decode', () async {
    // A path missing from `pubspec.yaml`'s asset list, or misspelled, compiles
    // fine and throws only when a row paints. Loading each one here moves that
    // failure into CI, where adding an agent is a one-line diff and forgetting
    // the pubspec entry is the obvious way to get it wrong.
    for (final tool in AgentTool.values) {
      final data = await rootBundle.load(tool.iconAsset);
      expect(
        data.lengthInBytes,
        greaterThan(0),
        reason: '${tool.id} has an empty icon at ${tool.iconAsset}',
      );
      // It must also decode: a truncated download, or an HTML error page saved
      // under a .png, passes a length check and still fails to paint.
      final image = await decodeImageFromList(data.buffer.asUint8List());
      expect(image.width, greaterThan(0), reason: '${tool.id} will not decode');
    }
  });

  test('the chat-agent default is a runnable agent', () {
    // kChatAgent is what answers chats before the user picks — it must be one the
    // app can actually install and run, never a planned placeholder.
    expect(kChatAgent.runnable, isTrue);
  });
}
