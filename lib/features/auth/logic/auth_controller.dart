import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/cli_diagnostics.dart';
import '../../../infrastructure/cli/grid_cli_service.dart';
import '../../../infrastructure/providers.dart';
import 'auth_state.dart';
import 'device_login_parser.dart';
import 'session_controller.dart';

final authControllerProvider =
    NotifierProvider<AuthController, AuthState>(AuthController.new);

/// Live CLI output for the sign-in flow, surfaced on the login screen so a
/// stuck or browser-less login is debuggable — and the link copy-able — without
/// reaching the in-app Debug tab (which only exists once you're signed in).
final authLogProvider = NotifierProvider<AuthLog, List<String>>(AuthLog.new);

class AuthLog extends Notifier<List<String>> {
  @override
  List<String> build() => const [];
  void clear() => state = const [];
  void add(String line) => state = [...state, line];
}

/// Drives `grid auth login --no-browser`: spawns it, surfaces the device-login
/// URL + code as they stream in (the login screen opens the browser to that
/// URL — the CLI can't reliably open one when spawned from a GUI app), and
/// resolves on the process exit code.
class AuthController extends Notifier<AuthState> {
  GridProcess? _process;

  /// How long to wait for the sign-in link to appear before giving up. A broken
  /// or hung CLI must surface as an error, never an endless spinner.
  static const _linkTimeout = Duration(seconds: 30);

  @override
  AuthState build() {
    ref.onDispose(() => _process?.kill());
    return const AuthIdle();
  }

  Future<void> login() async {
    final service = ref.read(gridCliServiceProvider);
    if (service == null) {
      state = const AuthFailure('grid executable not found.');
      return;
    }

    state = const AuthStarting();
    final parser = DeviceLoginParser();
    final log = ref.read(authLogProvider.notifier)..clear();

    // `--no-browser` tells the CLI to print the device-login URL instead of
    // opening a browser itself (which silently fails when spawned from the GUI
    // app, leaving the screen stuck on "Signing in…"). The login screen opens
    // the URL — see _openInBrowser.
    const args = <String>['auth', 'login', '--no-browser'];
    log.add('\$ grid ${args.join(' ')}');
    final proc = await service.start(args);
    _process = proc;

    proc.lines.listen((line) {
      log.add(line.text);
      parser.feed(line.text);
      final login = parser.result;
      if (login != null && state is! AuthAwaitingApproval) {
        state = AuthAwaitingApproval(url: login.url, userCode: login.userCode);
      }
    });

    // If the link never streams in, the CLI is stuck or crashed — bail with a
    // readable reason instead of spinning forever on "Signing in…".
    final timeout = Timer(_linkTimeout, () {
      if (identical(_process, proc) && state is AuthStarting) {
        proc.kill();
        state = AuthFailure(diagnoseCliFailure(ref.read(authLogProvider),
            headline: 'Timed out waiting for the sign-in link (30s).'));
      }
    });

    final exitCode = await proc.exitCode;
    timeout.cancel();

    if (exitCode == 0) {
      // Re-read cli.toml [auth] (the login gate) and credentials.toml (networks)
      // so RootView swaps LoginScreen → HomeShell instead of spinning forever.
      ref.invalidate(authSessionProvider);
      ref.invalidate(sessionProvider);
      state = const AuthSuccess();
      return;
    }
    // Don't clobber a state a timeout or cancel already settled.
    if (identical(_process, proc) &&
        (state is AuthStarting || state is AuthAwaitingApproval)) {
      state = AuthFailure(diagnoseCliFailure(ref.read(authLogProvider),
          headline: 'Login failed (exit $exitCode).'));
    }
  }

  void cancel() {
    _process?.kill();
    state = const AuthIdle();
  }

  /// Sign out. grid 0.1.0 keeps the session in `cli.toml [auth]` and ships no
  /// `grid auth logout`, so we clear it ourselves: strip `[auth]` from cli.toml
  /// (preserving provider/pricing) and drop the legacy credentials file. The
  /// session watchers then route back to the login screen.
  Future<void> logout() async {
    final store = ref.read(gridHomeStoreProvider);
    store.clearCliAuth();
    store.clearCredentials();
    ref.invalidate(authSessionProvider);
    ref.invalidate(sessionProvider);
    state = const AuthIdle();
  }
}
