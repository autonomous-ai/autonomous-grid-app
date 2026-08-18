import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grid_app/features/agents/logic/adapters/claude_browser.dart';
import 'package:grid_app/features/agents/logic/adapters/claude_chat_sender.dart';
import 'package:grid_app/features/agents/logic/agent_providers.dart';
import 'package:grid_app/features/agents/logic/chrome_setup_controller.dart';
import 'package:grid_app/infrastructure/cli/chrome_extension_probe.dart';
import 'package:grid_app/infrastructure/cli/claude_exec_event.dart';
import 'package:grid_app/infrastructure/cli/claude_exec_service.dart';

void main() {
  late Directory home;

  setUp(() {
    home = Directory.systemTemp.createTempSync('chrome-setup-');
    // A Chrome carrying the extension but no connection to Claude Code — the
    // state a user lands in the moment they install it from the store.
    Directory(
      '${home.path}/Library/Application Support/Google/Chrome/Default/'
      'Extensions/$kClaudeInChromeExtensionId',
    ).createSync(recursive: true);
  });

  tearDown(() => home.deleteSync(recursive: true));

  ProviderContainer containerWith(ClaudeExecService? service) =>
      ProviderContainer(
        overrides: [
          claudeExecServiceProvider.overrideWithValue(service),
          chromeExtensionProbeProvider.overrideWithValue(
            ChromeExtensionProbe(userHome: home.path),
          ),
          agentWorkspaceDirProvider.overrideWithValue(home),
        ],
      );

  test(
    'the connect step is what installs the piece Chrome reads: the app only '
    'passes --chrome once that piece exists, so nothing else ever could',
    () async {
      final service = _FakeExec(onRun: () => _writeHost(home));
      final container = containerWith(service);
      addTearDown(container.dispose);

      await container.read(chromeSetupProvider.notifier).connect();

      expect(container.read(chromeSetupProvider), isA<ChromeSetupDone>());
      expect(service.lastChrome, isTrue);
    },
  );

  test('the run reaches Claude Code own sign-in: the relay credentials are '
      'dropped, not overridden, or the extension refuses every call', () async {
    final service = _FakeExec(onRun: () => _writeHost(home));
    final container = containerWith(service);
    addTearDown(container.dispose);

    await container.read(chromeSetupProvider.notifier).connect();

    expect(service.lastDropped, kClaudeRelayEnvKeys);
    expect(service.lastEnvironment, isEmpty);
  });

  test('a run that leaves nothing on disk is a failure with a way out, not a '
      'green tick — the answer proves nothing, the file does', () async {
    final container = containerWith(_FakeExec(onRun: () {}));
    addTearDown(container.dispose);

    await container.read(chromeSetupProvider.notifier).connect();

    final state = container.read(chromeSetupProvider);
    expect(state, isA<ChromeSetupFailed>());
    expect((state as ChromeSetupFailed).message, contains('Sign in'));
  });

  test('a Claude Code that will not start says so in its own words rather than '
      'spinning forever', () async {
    final container = containerWith(
      _FakeExec(onRun: () => throw const ClaudeExecException('no such file')),
    );
    addTearDown(container.dispose);

    await container.read(chromeSetupProvider.notifier).connect();

    final state = container.read(chromeSetupProvider);
    expect(state, isA<ChromeSetupFailed>());
    expect((state as ChromeSetupFailed).message, 'no such file');
  });

  test('with Claude Code missing altogether the step fails before it starts a '
      'process', () async {
    final container = containerWith(null);
    addTearDown(container.dispose);

    await container.read(chromeSetupProvider.notifier).connect();

    expect(container.read(chromeSetupProvider), isA<ChromeSetupFailed>());
  });
}

/// The manifest Claude Code writes on its first `--chrome` run, which is the
/// only thing this step is really after.
void _writeHost(Directory home) => File(
  '${home.path}/Library/Application Support/Google/Chrome/'
  'NativeMessagingHosts/$kClaudeCodeNativeHost.json',
)..createSync(recursive: true);

/// A Claude Code that runs instantly and records how it was called.
class _FakeExec implements ClaudeExecService {
  _FakeExec({required this.onRun});

  final void Function() onRun;

  bool? lastChrome;
  Set<String>? lastDropped;
  Map<String, String>? lastEnvironment;

  @override
  ClaudeExecRun run({
    required String workdir,
    required String prompt,
    required String model,
    required Map<String, String> environment,
    String? resumeSessionId,
    String? mcpConfigPath,
    bool chrome = false,
    Set<String> dropEnvironment = const {},
  }) {
    lastChrome = chrome;
    lastDropped = dropEnvironment;
    lastEnvironment = environment;
    onRun();
    return ClaudeExecRun(
      events: const Stream<ClaudeExecEvent>.empty(),
      done: Future<void>.value(),
      kill: () {},
      answerPermission: (_, _) {},
    );
  }
}
