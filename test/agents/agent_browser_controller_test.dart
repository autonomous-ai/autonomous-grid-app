import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/agent_browser_controller.dart';
import 'package:grid_app/infrastructure/cli/chrome_bridge_service.dart';
import 'package:grid_app/infrastructure/state/agent_browser_choice.dart';
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

  test('a fresh install never lets an agent open a browser — something moving '
      'while you type is the thing this default prevents', () {
    expect(container.read(agentBrowserChoiceProvider), AgentBrowserChoice.none);
  });

  test('picking the clean window is remembered but opens nothing: the browser '
      'starts when a turn needs it, not when the choice is made', () {
    container.read(agentBrowserProvider).choose(AgentBrowserChoice.cleanWindow);

    expect(
      container.read(agentBrowserChoiceProvider),
      AgentBrowserChoice.cleanWindow,
    );
    expect(bridge.disposed, isFalse);
  });

  test('moving off the clean window closes the browser the app is holding, so '
      'the new answer takes effect now rather than at the next launch', () {
    final controller = container.read(agentBrowserProvider)
      ..choose(AgentBrowserChoice.cleanWindow);

    controller.choose(AgentBrowserChoice.none);

    expect(container.read(agentBrowserChoiceProvider), AgentBrowserChoice.none);
    expect(bridge.disposed, isTrue);
  });

  test('switching to the user’s own browser also closes the window the app '
      'opened — two browsers answering one chat is one too many', () {
    final controller = container.read(agentBrowserProvider)
      ..choose(AgentBrowserChoice.cleanWindow);

    controller.choose(AgentBrowserChoice.yourBrowser);

    expect(bridge.disposed, isTrue);
  });

  test('the choice survives a restart, so a user who answered is not asked to '
      'answer again every launch', () {
    container.read(agentBrowserProvider).choose(AgentBrowserChoice.gridTab);

    final reopened = ProviderContainer(
      overrides: [
        chatPrefsStoreProvider.overrideWithValue(
          ChatPrefsStore(file: File('${dir.path}/chat_prefs.json')),
        ),
      ],
    );
    addTearDown(reopened.dispose);

    expect(
      reopened.read(agentBrowserChoiceProvider),
      AgentBrowserChoice.gridTab,
    );
  });

  test('a settings file from before the choice existed keeps the answer it '
      'held: a ticked switch asked for a browser of the app’s own', () {
    File('${dir.path}/legacy.json').writeAsStringSync('{"agentBrowser": true}');
    final legacy = ProviderContainer(
      overrides: [
        chatPrefsStoreProvider.overrideWithValue(
          ChatPrefsStore(file: File('${dir.path}/legacy.json')),
        ),
      ],
    );
    addTearDown(legacy.dispose);

    expect(
      legacy.read(agentBrowserChoiceProvider),
      AgentBrowserChoice.cleanWindow,
    );
  });
}

class _FakeBridge extends ChromeBridge {
  bool disposed = false;

  @override
  void dispose() => disposed = true;
}
