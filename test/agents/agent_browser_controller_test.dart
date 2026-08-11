import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_browser_controller.dart';
import 'package:grid_app/infrastructure/cli/chrome_bridge_service.dart';
import 'package:grid_app/infrastructure/state/chat_prefs_store.dart';

void main() {
  late Directory dir;
  late _FakeBridge bridge;
  late ProviderContainer container;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('agent-browser-');
    bridge = _FakeBridge();
    container = ProviderContainer(
      overrides: [
        chatPrefsStoreProvider.overrideWithValue(
          ChatPrefsStore(file: File('${dir.path}/chat_prefs.json')),
        ),
        chromeBridgeProvider.overrideWithValue(bridge),
      ],
    );
  });

  tearDown(() {
    container.dispose();
    dir.deleteSync(recursive: true);
  });

  test(
    'a fresh install never lets an agent open a browser — a window appearing '
    'while you type is the thing this default prevents',
    () {
      expect(container.read(agentBrowserAllowedProvider), isFalse);
    },
  );

  test('turning it on is remembered but opens nothing: the browser starts when '
      'a turn needs it, not when the switch is flipped', () {
    container.read(agentBrowserProvider).allow(true);

    expect(container.read(agentBrowserAllowedProvider), isTrue);
    expect(bridge.disposed, isFalse);
  });

  test('turning it off closes the browser the app is holding, so "no" takes '
      'effect now rather than at the next launch', () {
    final controller = container.read(agentBrowserProvider)..allow(true);

    controller.allow(false);

    expect(container.read(agentBrowserAllowedProvider), isFalse);
    expect(bridge.disposed, isTrue);
  });

  test('the choice survives a restart, so a user who said no is not asked to '
      'say it again every launch', () {
    container.read(agentBrowserProvider).allow(true);

    final reopened = ProviderContainer(
      overrides: [
        chatPrefsStoreProvider.overrideWithValue(
          ChatPrefsStore(file: File('${dir.path}/chat_prefs.json')),
        ),
      ],
    );
    addTearDown(reopened.dispose);

    expect(reopened.read(agentBrowserAllowedProvider), isTrue);
  });
}

class _FakeBridge extends ChromeBridge {
  bool disposed = false;

  @override
  void dispose() => disposed = true;
}
