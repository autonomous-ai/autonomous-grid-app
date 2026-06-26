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

/// Drives `grid auth login --no-browser`: spawns it, surfaces the URL + code as
/// they stream in, and resolves on the process exit code (cli.py:357/381).
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
    final output = <String>[];

    final apiUrl = ref.read(gridApiUrlProvider);
    final proc = await service.start([
      'auth', 'login', '--no-browser',
      if (apiUrl.isNotEmpty) ...['--api-url', apiUrl],
    ]);
    _process = proc;

    proc.lines.listen((line) {
      output.add(line.text);
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
        state = AuthFailure(diagnoseCliFailure(output,
            headline: 'Timed out waiting for the sign-in link (30s).'));
      }
    });

    final exitCode = await proc.exitCode;
    timeout.cancel();

    if (exitCode == 0) {
      ref.invalidate(sessionProvider);
      state = const AuthSuccess();
      return;
    }
    // Don't clobber a state a timeout or cancel already settled.
    if (identical(_process, proc) &&
        (state is AuthStarting || state is AuthAwaitingApproval)) {
      state = AuthFailure(diagnoseCliFailure(output,
          headline: 'Login failed (exit $exitCode).'));
    }
  }

  void cancel() {
    _process?.kill();
    state = const AuthIdle();
  }

  /// Sign out: best-effort `grid auth logout` (if the CLI supports it), then
  /// clear the local credentials so the app drops back to the login screen.
  Future<void> logout() async {
    final service = ref.read(gridCliServiceProvider);
    await service?.run(['auth', 'logout']);
    ref.read(gridHomeStoreProvider).clearCredentials();
    ref.invalidate(sessionProvider);
    state = const AuthIdle();
  }
}
