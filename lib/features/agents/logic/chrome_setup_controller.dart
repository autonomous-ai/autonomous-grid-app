import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/chrome_extension_probe.dart';
import '../../../infrastructure/cli/claude_exec_service.dart';
import '../../../infrastructure/logging/app_log.dart';
import 'adapters/claude_browser.dart';
import 'adapters/claude_chat_sender.dart';
import 'agent_browser_controller.dart';
import 'agent_providers.dart';

/// How far the one-off "connect my own Chrome" step has got.
sealed class ChromeSetupState {
  const ChromeSetupState();
}

/// Nothing has been asked for yet.
final class ChromeSetupIdle extends ChromeSetupState {
  const ChromeSetupIdle();
}

/// Claude Code is running its browser-enabled turn — the run that installs the
/// piece Chrome needs.
final class ChromeSetupRunning extends ChromeSetupState {
  const ChromeSetupRunning();
}

/// The connection is on disk. Chrome reads it at startup, so it has to be quit
/// and reopened before the assistant can drive it.
final class ChromeSetupDone extends ChromeSetupState {
  const ChromeSetupDone();
}

/// It didn't work, in words the user can act on.
final class ChromeSetupFailed extends ChromeSetupState {
  const ChromeSetupFailed(this.message);

  final String message;
}

/// A throwaway prompt: the answer is discarded, and the point of the run is the
/// setup Claude Code does on its way to answering.
const String _kSetupPrompt = 'Reply with the single word: ready';

/// The alias to run it on. `claude --help` (2.1.183) documents `fable`, `opus`
/// and `sonnet`; `haiku` is not among them, and an alias the binary rejects
/// would fail this step for a reason that has nothing to do with the browser.
/// The turn is one word long, so the smallest documented brain is enough.
const String _kSetupModel = 'sonnet';

/// Long enough for a cold `claude` start on a busy machine, short enough that a
/// wedged process doesn't leave a spinner running all afternoon.
const Duration _kSetupTimeout = Duration(seconds: 90);

/// Runs Claude Code once with `--chrome` so it installs the connection Chrome
/// needs, then re-reads the disk to see whether it landed.
///
/// This is the piece that was missing, not a convenience: the app only passes
/// `--chrome` on a turn it has already decided can reach the extension, and that
/// decision requires the very file this run creates. Left alone the two wait for
/// each other forever — a user could install the extension, see nothing change,
/// and have no way in from inside the app.
///
/// Deliberately user-initiated. It starts a process, spends a little of the
/// user's own Claude quota, and is the kind of thing the app never does behind
/// somebody's back.
final chromeSetupProvider =
    NotifierProvider<ChromeSetupController, ChromeSetupState>(
      ChromeSetupController.new,
    );

class ChromeSetupController extends Notifier<ChromeSetupState> {
  @override
  ChromeSetupState build() => const ChromeSetupIdle();

  Future<void> connect() async {
    if (state is ChromeSetupRunning) return;
    final service = ref.read(claudeExecServiceProvider);
    if (service == null) {
      state = const ChromeSetupFailed(
        "Claude Code isn't installed on this computer yet.",
      );
      return;
    }

    state = const ChromeSetupRunning();
    final log = ref.read(appLogProvider);
    try {
      final run = service.run(
        workdir: ref.read(agentWorkspaceDirProvider).path,
        prompt: _kSetupPrompt,
        model: _kSetupModel,
        // The extension only talks to Claude Code's own sign-in, so the relay's
        // credentials have to be gone from this run rather than overridden.
        environment: const {},
        dropEnvironment: kClaudeRelayEnvKeys,
        chrome: true,
      );
      // Listened to, not ignored: an unread stream leaves the child blocked on
      // a full stdout pipe, which would look exactly like a hung setup.
      final drained = run.events.drain<void>();
      await Future.wait([drained, run.done]).timeout(
        _kSetupTimeout,
        onTimeout: () {
          run.kill();
          throw TimeoutException('setup timed out', _kSetupTimeout);
        },
      );
    } on ClaudeExecException catch (error) {
      log.failure('agent', 'Chrome setup: ${error.message}');
      state = ChromeSetupFailed(error.message);
      return;
    } on TimeoutException {
      log.failure('agent', 'Chrome setup: Claude Code did not finish in time');
      state = const ChromeSetupFailed(
        'Claude Code took too long to answer. Try again in a moment.',
      );
      return;
    }

    // The run's own answer proves nothing — what matters is whether the file
    // Chrome reads is there now, so the verdict comes from the disk (§7).
    ref.read(agentBrowserProvider).recheck();
    if (ref.read(chromeExtensionStateProvider) != ChromeExtensionState.ready) {
      log.failure(
        'agent',
        'Chrome setup: the browser connection is still not '
            'on disk after a --chrome run',
      );
      state = const ChromeSetupFailed(
        "Claude Code ran, but Chrome still isn't connected. Sign in to Claude "
        'Code in a terminal, then try again.',
      );
      return;
    }
    log.info(
      'agent',
      'Chrome setup: connection installed, Chrome must restart',
    );
    state = const ChromeSetupDone();
  }
}
