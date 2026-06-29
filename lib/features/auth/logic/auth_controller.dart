import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../infrastructure/cli/grid_cli_service.dart';
import '../../../infrastructure/providers.dart';
import '../../network/logic/create_network_controller.dart';
import 'auth_state.dart';
import 'device_login_parser.dart';
import 'session_controller.dart';

final authControllerProvider =
    NotifierProvider<AuthController, AuthState>(AuthController.new);

/// Drives `grid login --no-browser`: spawns it, surfaces the device-login URL +
/// code as they stream in, and resolves on the process exit code (cli/auth.py).
class AuthController extends Notifier<AuthState> {
  GridProcess? _process;

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
    final errorLines = <String>[];

    // The merged CLI's device sign-in reads its own control-plane URL from
    // `~/.grid`, so the old `--api-url` knob is gone.
    _process = await service.start(['login', '--no-browser']);
    _process!.lines.listen((line) {
      if (line.isStderr) errorLines.add(line.text);
      parser.feed(line.text);
      final login = parser.result;
      if (login != null && state is! AuthAwaitingApproval) {
        state = AuthAwaitingApproval(url: login.url, userCode: login.userCode);
      }
    });

    final exitCode = await _process!.exitCode;
    if (exitCode == 0) {
      ref.invalidate(sessionProvider);
      state = const AuthSuccess();
      // Brand-new accounts land with no grids — give them a starter one named
      // after them. Runs in the background; the list refreshes when it lands.
      unawaited(ref
          .read(createNetworkControllerProvider.notifier)
          .createFirstGridIfNeeded());
      return;
    }
    state = AuthFailure(
      errorLines.isNotEmpty
          ? errorLines.join('\n')
          : 'Login failed (exit $exitCode).',
    );
  }

  void cancel() {
    _process?.kill();
    state = const AuthIdle();
  }

  /// Sign out via `grid logout`, which clears the stored cloud credentials and
  /// the active-grid pointer in `state.json`. Falls back to deleting the local
  /// credentials directly when the CLI is unavailable — `~/.grid` is the app's
  /// source of truth either way, so the app drops to the login screen.
  Future<void> logout() async {
    final service = ref.read(gridCliServiceProvider);
    if (service != null) {
      await service.run(['logout']);
    } else {
      ref.read(gridHomeStoreProvider).clearCredentials();
    }
    ref.invalidate(sessionProvider);
    state = const AuthIdle();
  }
}
