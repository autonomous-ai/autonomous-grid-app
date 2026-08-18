import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/chrome_host_installer.dart';
import '../../../infrastructure/logging/app_log.dart';
import 'adapters/claude_tool.dart';
import 'agent_browser_controller.dart';

/// How far the "connect my own Chrome" step has got.
sealed class ChromeSetupState {
  const ChromeSetupState();
}

/// Nothing has been asked for yet.
final class ChromeSetupIdle extends ChromeSetupState {
  const ChromeSetupIdle();
}

/// The connection is being written.
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

/// Why there is nothing to write on a machine with no installer. Both reasons
/// end the same way for the user — no connection — so they share one sentence
/// that is true of either, rather than a branch the card cannot act on.
const String _whyUnavailable =
    "Grid can't connect Chrome here: it needs Claude Code installed, on macOS "
    'or Linux.';

/// Writes the connection, for the browsers this computer has.
final chromeHostInstallerProvider = Provider<ChromeHostInstaller?>((ref) {
  final binary = ref.watch(claudePathProvider);
  if (binary == null || !ChromeHostInstaller.supported) return null;
  return ChromeHostInstaller(claudeBinary: binary);
});

/// Puts Claude Code's browser connection on disk — at launch, and again behind
/// the card's own button.
///
/// **It used to cost a turn.** The connection is two small files, and the only
/// thing that wrote them was Claude Code's first `--chrome` run, so this app
/// ran a throwaway prompt (`Reply with the single word: ready`) purely for the
/// files it left behind: a model call, the user's own quota, and a wait, to
/// write ~400 bytes. The Claude desktop app doesn't do that — it ships its host
/// and refreshes its manifest every launch — and neither does this now.
///
/// Because it is free and silent, it runs at launch (`ChromeConnectScope`)
/// rather than waiting for somebody to find a button. The button stays for the
/// one case launch can't cover: a computer whose disk said no.
final chromeSetupProvider =
    NotifierProvider<ChromeSetupController, ChromeSetupState>(
      ChromeSetupController.new,
    );

class ChromeSetupController extends Notifier<ChromeSetupState> {
  @override
  ChromeSetupState build() => const ChromeSetupIdle();

  /// Write the connection and re-read the machine.
  ///
  /// [announce] is false for the launch pass: a card that opened saying "quit
  /// Chrome and open it again" to a user who never asked for a browser would be
  /// nagging, so the launch pass changes what the lane *is* and lets the card
  /// report that on its own. Pressing the button announces.
  Future<void> connect({bool announce = true}) async {
    if (state is ChromeSetupRunning) return;
    final installer = ref.read(chromeHostInstallerProvider);
    if (installer == null) {
      if (announce) state = const ChromeSetupFailed(_whyUnavailable);
      return;
    }

    state = const ChromeSetupRunning();
    final log = ref.read(appLogProvider);
    final ChromeHostInstall install;
    try {
      install = await installer.install();
    } on FileSystemException catch (error) {
      log.failure('agent', 'Chrome connect: ${error.message} ${error.path}');
      state = const ChromeSetupFailed(
        "Grid couldn't write the browser connection. Check that Chrome is "
        'installed and try again.',
      );
      return;
    }

    if (install.browsers.isEmpty) {
      log.info('agent', 'Chrome connect: no Chromium browser on this computer');
      state = announce
          ? const ChromeSetupFailed(
              'Grid found no Chrome on this computer to connect to.',
            )
          : const ChromeSetupIdle();
      return;
    }

    // The verdict comes from the machine, not from the write: what decides the
    // lane is a browser that has connected, and a browser restart is the one
    // thing this step cannot do for the user (§7).
    ref.read(agentBrowserProvider).recheck();
    final wrote = install.changed
        ? 'newly written — Chrome must restart'
        : 'unchanged';
    log.info(
      'agent',
      'Chrome connect: ${install.browsers.length} browser(s) set up, $wrote',
    );
    state = announce ? const ChromeSetupDone() : const ChromeSetupIdle();
  }
}
